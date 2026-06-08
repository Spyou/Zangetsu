import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import 'base_provider.dart';

/// Native MethodChannel bridging to the CloudStream plugin host. All methods
/// are async, Android-only, and return JSON-shaped collections. Every call is
/// guarded by [Platform.isAndroid] at the call site; the channel itself never
/// throws past the guards below (failures degrade to empty/safe values).
const MethodChannel _csChannel = MethodChannel('zangetsu/cloudstream');

/// CloudStream source types that map to the [ProviderType.anime] bucket.
/// Everything else (Movie, TvSeries, AsianDrama, etc.) is treated as
/// [ProviderType.movie] — the catalog's non-anime value.
const Set<String> _kAnimeTypes = {'Anime', 'AnimeMovie', 'OVA'};

/// Maps a CloudStream type string to the app's [ProviderType]. Returns null
/// when there's no usable hint so callers can fall back to a per-source default.
ProviderType? _typeFromCsType(String? csType) {
  if (csType == null || csType.isEmpty) return null;
  return _kAnimeTypes.contains(csType)
      ? ProviderType.anime
      : ProviderType.movie;
}

/// A single installed CloudStream source, adapted to the app's [BaseProvider]
/// contract so it routes through [SourceRepository] exactly like a JS provider.
///
/// Identified by `cs:<name>` where `<name>` is the CloudStream source name with
/// NO prefix — the native side keys plugins by that bare name, so every channel
/// call passes [name] (not [sourceId]).
class CloudStreamProvider implements BaseProvider {
  CloudStreamProvider({
    required this.name,
    required this.lang,
    required this.types,
  });

  /// The bare CloudStream source name (no `cs:` prefix). Passed to the channel.
  final String name;
  final String lang;
  final List<String> types;

  @override
  String get sourceId => 'cs:$name';

  @override
  String get displayName => name;

  /// Whether ANY of this source's advertised types is anime; drives the
  /// provider-level [ProviderType] and the default for items without a type.
  ProviderType get _providerType =>
      types.any(_kAnimeTypes.contains) ? ProviderType.anime : ProviderType.movie;

  /// Public type accessor (anime vs movie/series) for UI bucketing — e.g. the
  /// home source switcher.
  ProviderType get providerType => _providerType;

  @override
  Future<ProviderInfo> getInfo() async => ProviderInfo(
        name: name,
        lang: lang,
        // CloudStream plugins don't expose a single base URL; the host owns it.
        baseUrl: '',
        type: _providerType,
      );

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _csChannel.invokeMethod<List<dynamic>>('search', {
        'name': name,
        'query': query,
      });
      return (raw ?? const []).map(_mediaItemFromMap).toList();
    } catch (e) {
      debugPrint('[cloudstream] search failed for $name: $e');
      return const [];
    }
  }

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    if (!Platform.isAndroid) {
      return MediaDetail(
        id: url,
        title: '',
        url: url,
        type: _providerType,
        sourceId: sourceId,
      );
    }
    final raw = await _csChannel.invokeMethod<Map<dynamic, dynamic>>('load', {
      'name': name,
      'url': url,
    });
    final m = _asMap(raw);
    final episodesRaw = m['episodes'];
    final episodes = <Episode>[];
    if (episodesRaw is List) {
      for (final e in episodesRaw) {
        episodes.add(_episodeFromMap(_asMap(e)));
      }
    }
    return MediaDetail(
      id: (m['url'] ?? url).toString(),
      title: (m['name'] ?? '').toString(),
      cover: (m['posterUrl'] as String?),
      url: (m['url'] ?? url).toString(),
      description: (m['plot'] as String?),
      episodes: episodes,
      year: (m['year'] as num?)?.toInt().toString(),
      type: _typeFromCsType(m['type'] as String?) ?? _providerType,
      sourceId: sourceId,
    );
  }

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) async {
    final detail = await getDetail(url, category: category);
    return detail.episodes;
  }

  @override
  Future<List<VideoSource>> getVideoSources(String episodeUrl) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
      'loadLinks',
      {'name': name, 'data': episodeUrl},
    );
    final m = _asMap(raw);

    // Subtitles are shared across every stream for this episode.
    final subtitles = <Subtitle>[];
    final subsRaw = m['subtitles'];
    if (subsRaw is List) {
      for (final s in subsRaw) {
        final sm = _asMap(s);
        final subUrl = (sm['url'] ?? '').toString();
        if (subUrl.isEmpty) continue;
        subtitles.add(
          Subtitle(url: subUrl, lang: (sm['lang'] ?? '').toString()),
        );
      }
    }

    final sources = <VideoSource>[];
    final srcRaw = m['sources'];
    if (srcRaw is List) {
      for (final s in srcRaw) {
        final sm = _asMap(s);
        final streamUrl = (sm['url'] ?? '').toString();
        if (streamUrl.isEmpty) continue;
        // Torrents / magnet links aren't playable in the app's player.
        final lower = streamUrl.toLowerCase();
        if (lower.startsWith('magnet:') || lower.endsWith('.torrent')) continue;

        final quality = (sm['quality'] as num?)?.toInt() ?? 0;
        final isM3u8 = sm['isM3u8'] == true;
        final referer = (sm['referer'] ?? '').toString();
        final headers = <String, String>{};
        final rawHeaders = sm['headers'];
        if (rawHeaders is Map) {
          rawHeaders.forEach((k, v) => headers['$k'] = '$v');
        }
        if (referer.isNotEmpty) headers['Referer'] = referer;

        sources.add(
          VideoSource(
            url: streamUrl,
            quality: quality > 0 ? '${quality}p' : 'auto',
            label: (sm['name'] as String?),
            container: isM3u8 ? SourceContainer.hls : SourceContainer.mp4,
            headers: headers.isEmpty ? null : headers,
            subtitles: subtitles,
          ),
        );
      }
    }
    return sources;
  }

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    // CloudStream's home feed is surfaced via [getHome]; there's no separate
    // popular endpoint on the channel.
    return const [];
  }

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
    if (!Platform.isAndroid) return null;
    final raw = await _csChannel.invokeMethod<List<dynamic>>(
      'getHome',
      {'name': name},
    );
    if (raw == null || raw.isEmpty) return null;
    final sections = <HomeSection>[];
    for (final r in raw) {
      final m = _asMap(r);
      final items =
          (m['items'] as List?)?.map(_mediaItemFromMap).toList() ??
          const <MediaItem>[];
      if (items.isEmpty) continue;
      sections.add(
        HomeSection(title: (m['title'] ?? '').toString(), items: items),
      );
    }
    return sections.isEmpty ? null : sections;
  }

  // ── mapping helpers ───────────────────────────────────────────────────────

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  MediaItem _mediaItemFromMap(dynamic raw) {
    final m = _asMap(raw);
    final url = (m['url'] ?? '').toString();
    Map<String, String>? coverHeaders;
    final ph = m['posterHeaders'];
    if (ph is Map) {
      coverHeaders = ph.map((k, v) => MapEntry('$k', '$v'));
    }
    return MediaItem(
      id: url,
      title: (m['name'] ?? '').toString(),
      cover: (m['posterUrl'] as String?),
      coverHeaders: coverHeaders,
      url: url,
      type: _typeFromCsType(m['type'] as String?) ?? _providerType,
      sourceId: sourceId,
    );
  }

  Episode _episodeFromMap(Map<String, dynamic> e) {
    final season = (e['season'] as num?)?.toInt();
    final episode = (e['episode'] as num?)?.toInt();
    final id = (season != null || episode != null)
        ? 'S${season ?? 0}E${episode ?? 0}'
        : (e['data'] ?? '').toString();
    return Episode(
      id: id,
      title: (e['name'] ?? '').toString(),
      number: episode?.toDouble(),
      // The opaque CloudStream dataUrl — passed straight back to loadLinks.
      url: (e['data'] ?? '').toString(),
      thumbnail: (e['posterUrl'] as String?),
    );
  }
}

/// A persisted CloudStream repo and the loaded sources that belong to it. Built
/// by [CloudStreamManager.repoGroups] for the grouped Providers UI.
///   * [url]    — the repo manifest URL (empty for the synthetic "Other" group).
///   * [name]   — the repo's advertised name.
///   * [owner]  — parsed from the URL (GitHub owner, else the host).
///   * [sources]— the loaded providers whose [CloudStreamProvider.displayName]
///                matches one of the repo's advertised plugin names.
class CsRepoGroup {
  const CsRepoGroup({
    required this.url,
    required this.name,
    required this.owner,
    required this.sources,
  });

  final String url;
  final String name;
  final String owner;
  final List<CloudStreamProvider> sources;
}

/// Owns the set of installed CloudStream sources and the channel calls that
/// build them. Android-only: every method is a no-op (returns empty) elsewhere.
///
/// Repos added via [addRepo] are persisted to a small Hive box ([boxName]) so
/// the owner/repo grouping survives a restart even though the loaded sources
/// themselves are rebuilt from the native host each launch.
class CloudStreamManager extends ChangeNotifier {
  /// Hive box name for the persisted repo list.
  static const String boxName = 'cs_repos';
  static const String _reposKey = 'repos';

  /// Opens the persisted-repo box. Safe on every platform (only the channel
  /// calls are Android-gated). Must be called before constructing the manager.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  final Map<String, CloudStreamProvider> _providers = {};

  /// In-memory mirror of the persisted repo list: each entry is
  /// `{url, name, pluginNames:[...]}`. Loaded on [loadInstalled], upserted on
  /// [addRepo].
  final List<Map<String, dynamic>> _repos = [];

  Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// All installed CloudStream providers.
  List<CloudStreamProvider> get all => _providers.values.toList();

  /// Provider for a `cs:<name>` source id, or null when not installed.
  BaseProvider? get(String sourceId) => _providers[sourceId];

  /// The loaded sources grouped by their origin repo (for the grouped UI).
  ///
  /// For each persisted repo, [CsRepoGroup.sources] are the loaded providers
  /// whose [CloudStreamProvider.displayName] is in that repo's `pluginNames`
  /// (case-insensitive). Any loaded providers not matched to a persisted repo
  /// are collected into a trailing synthetic "Other" group (only when present)
  /// — this covers sources loaded from the host cache before persistence.
  List<CsRepoGroup> get repoGroups {
    final groups = <CsRepoGroup>[];
    final claimed = <String>{}; // sourceIds already placed in a repo group

    for (final repo in _repos) {
      final names = <String>{};
      final rawNames = repo['pluginNames'];
      if (rawNames is List) {
        for (final n in rawNames) {
          names.add('$n'.toLowerCase());
        }
      }
      final sources = <CloudStreamProvider>[];
      for (final p in _providers.values) {
        if (names.contains(p.displayName.toLowerCase())) {
          sources.add(p);
          claimed.add(p.sourceId);
        }
      }
      groups.add(
        CsRepoGroup(
          url: (repo['url'] ?? '').toString(),
          name: (repo['name'] ?? '').toString(),
          owner: _ownerOf((repo['url'] ?? '').toString()),
          sources: sources,
        ),
      );
    }

    final orphans = _providers.values
        .where((p) => !claimed.contains(p.sourceId))
        .toList();
    if (orphans.isNotEmpty) {
      groups.add(
        CsRepoGroup(url: '', name: 'Other', owner: '', sources: orphans),
      );
    }
    return groups;
  }

  /// Parses the repo owner from [url]: the GitHub owner for
  /// `raw.githubusercontent.com/<owner>/...` or `github.com/<owner>/...`,
  /// otherwise the URL host. Empty when unparseable.
  String _ownerOf(String url) {
    if (url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final host = uri.host.toLowerCase();
    if (host == 'raw.githubusercontent.com' ||
        host == 'github.com' ||
        host == 'www.github.com') {
      if (uri.pathSegments.isNotEmpty && uri.pathSegments.first.isNotEmpty) {
        return uri.pathSegments.first;
      }
    }
    return uri.host;
  }

  /// Adds a CloudStream repo by [url], persisting the repo's advertised name +
  /// plugin names, then (re)building the provider set from ALL loaded sources.
  /// Returns the count of sources now loaded. No-op on non-Android.
  Future<int> addRepo(String url) async {
    if (!Platform.isAndroid) return 0;
    try {
      final repo = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
        'addRepo',
        {'url': url},
      );
      _upsertRepo(repo, fallbackUrl: url);
      // Reload the full source set (the host now includes the new plugins).
      final raw = await _csChannel.invokeMethod<List<dynamic>>('listSources');
      _rebuildFrom(raw);
      notifyListeners();
      return _providers.length;
    } catch (e) {
      debugPrint('[cloudstream] addRepo failed: $e');
      rethrow;
    }
  }

  /// Upserts a `{name, url, pluginNames}` repo map into the persisted list,
  /// replacing any existing entry with the same url. Tolerant of missing keys.
  void _upsertRepo(Map<dynamic, dynamic>? repo, {required String fallbackUrl}) {
    final m = repo == null ? const {} : Map<String, dynamic>.from(repo);
    final repoUrl = (m['url'] ?? fallbackUrl).toString();
    final names = <String>[];
    final rawNames = m['pluginNames'];
    if (rawNames is List) {
      for (final n in rawNames) {
        names.add('$n');
      }
    }
    final entry = <String, dynamic>{
      'url': repoUrl,
      'name': (m['name'] ?? '').toString(),
      'pluginNames': names,
    };
    _repos.removeWhere((r) => (r['url'] ?? '').toString() == repoUrl);
    _repos.add(entry);
    _persistRepos();
  }

  void _persistRepos() {
    _box?.put(
      _reposKey,
      _repos.map((r) => Map<String, dynamic>.from(r)).toList(),
    );
  }

  /// Reads the persisted repo list into [_repos]. Each entry is normalized to
  /// `{url, name, pluginNames:[String...]}`.
  void _loadRepos() {
    _repos.clear();
    final raw = _box?.get(_reposKey);
    if (raw is! List) return;
    for (final r in raw) {
      if (r is! Map) continue;
      final m = Map<String, dynamic>.from(r);
      final names = <String>[];
      final rawNames = m['pluginNames'];
      if (rawNames is List) {
        for (final n in rawNames) {
          names.add('$n');
        }
      }
      _repos.add({
        'url': (m['url'] ?? '').toString(),
        'name': (m['name'] ?? '').toString(),
        'pluginNames': names,
      });
    }
  }

  /// Loads any cached/installed plugins into the provider set AND reads the
  /// persisted repo list into memory. No-op (channel) on non-Android; failures
  /// are swallowed so a missing native channel can't break startup.
  Future<void> loadInstalled() async {
    _loadRepos();
    if (!Platform.isAndroid) {
      notifyListeners();
      return;
    }
    try {
      final raw = await _csChannel.invokeMethod<List<dynamic>>('listSources');
      _rebuildFrom(raw);
    } catch (e) {
      debugPrint('[cloudstream] listSources failed: $e');
    }
    notifyListeners();
  }

  void _rebuildFrom(List<dynamic>? raw) {
    _providers.clear();
    for (final entry in raw ?? const []) {
      if (entry is! Map) continue;
      final m = Map<String, dynamic>.from(entry);
      final name = (m['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final types = <String>[];
      final rawTypes = m['types'];
      if (rawTypes is List) {
        for (final t in rawTypes) {
          types.add('$t');
        }
      }
      final provider = CloudStreamProvider(
        name: name,
        lang: (m['lang'] ?? '').toString(),
        types: types,
      );
      _providers[provider.sourceId] = provider;
    }
  }
}
