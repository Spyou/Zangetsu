import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_extras.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import 'base_provider.dart';

/// Native MethodChannel bridging to the CloudStream plugin host. All methods
/// are async, Android-only, and return JSON-shaped collections. Every call is
/// guarded by [Platform.isAndroid] at the call site; the channel itself never
/// throws past the guards below (failures degrade to empty/safe values).
const MethodChannel _csChannel = MethodChannel('zangetsu/cloudstream');

/// Whether the CloudStream source [apiName] exposes its OWN settings UI
/// (the plugin's `openSettings`, e.g. AnimePahe's server picker). Android-only;
/// any failure degrades to `false`.
Future<bool> csPluginHasSettings(String apiName) async {
  if (!Platform.isAndroid) return false;
  try {
    return await _csChannel.invokeMethod<bool>('hasPluginSettings', {
          'name': apiName,
        }) ??
        false;
  } catch (_) {
    return false;
  }
}

/// Opens the CloudStream source [apiName]'s OWN settings UI in the native host
/// activity (the plugin renders its bottom sheet / dialog). Android-only; safe
/// no-op on failure or other platforms.
Future<void> csPluginOpenSettings(String apiName) async {
  if (!Platform.isAndroid) return;
  try {
    await _csChannel.invokeMethod('openPluginSettings', {'name': apiName});
  } catch (_) {}
}

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

/// Per-repo cache-file tag — derived from the REPOSITORY URL the user added
/// (NOT the .cs3 file URL), exactly like CloudStream keys its plugin folders on
/// the repo url. This is what lets two repos that serve the SAME plugin file
/// (same internalName, even the same .cs3 URL) install independently: different
/// repo url → different tag → different cache file. MUST match the native
/// `RepoManager.repoTag` (Java `String.hashCode` then `Integer.toHexString`).
String _csRepoTag(String repoUrl) {
  final s = repoUrl.toLowerCase();
  var h = 0;
  for (var i = 0; i < s.length; i++) {
    h = (31 * h + s.codeUnitAt(i)) & 0xFFFFFFFF; // 32-bit wrap, like Java int
  }
  return h.toRadixString(
    16,
  ); // unsigned hex, lowercase — like Integer.toHexString
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
    this.sourcePlugin,
    this.disambiguate = false,
    this.repoLabel,
  });

  /// The bare CloudStream source name (no `cs:` prefix).
  final String name;
  final String lang;
  final List<String> types;

  /// The `.cs3` file id (`internalName@version`) that registered this source.
  /// Used to group it under (and delete it with) its repo. Null for sources
  /// loaded by an older build that didn't stamp it.
  final String? sourcePlugin;

  /// True when ANOTHER installed source shares this [name] (e.g. two "MovieBox"
  /// forks from different repos). Such a source identifies itself by its unique
  /// `.cs3` file id instead of its name, so the two don't collapse into one
  /// entry (install/uninstall/enable one without touching the other).
  final bool disambiguate;

  /// A short repo label shown after the name to tell same-named sources apart
  /// (e.g. "MovieBox (cncverse)"). Null → fall back to the file tag.
  final String? repoLabel;

  /// The key the native host resolves a call against. We prefer the unique
  /// `.cs3` file id so same-named sources address their OWN plugin; the host
  /// also accepts the bare name (legacy fallback), so older sources still work.
  String get hostKey =>
      (sourcePlugin != null && sourcePlugin!.isNotEmpty) ? sourcePlugin! : name;

  @override
  String get sourceId =>
      (disambiguate && sourcePlugin != null && sourcePlugin!.isNotEmpty)
      ? 'cs:${sourcePlugin!}'
      : 'cs:$name';

  @override
  String get displayName {
    final base = _prettyName(name);
    return disambiguate
        ? '$base (${repoLabel ?? sourcePlugin!.split('@').last})'
        : base;
  }

  /// A readable label for [n]. Some plugins (e.g. StremioX) register an added
  /// addon as a source named with whatever went in its "name" field — and users
  /// often paste the addon's full URL there, which makes a giant unusable label
  /// in the picker. Show just the host for a URL-like name. Identity ([sourceId])
  /// still uses the raw [name], so this is display-only.
  static String _prettyName(String n) {
    if (n.startsWith('http://') || n.startsWith('https://')) {
      try {
        final host = Uri.parse(n).host;
        if (host.isNotEmpty) return host;
      } catch (_) {}
    }
    return n;
  }

  /// Whether ANY of this source's advertised types is anime; drives the
  /// provider-level [ProviderType] and the default for items without a type.
  ProviderType get _providerType => types.any(_kAnimeTypes.contains)
      ? ProviderType.anime
      : ProviderType.movie;

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
        'name': hostKey,
        'query': query,
      });
      return (raw ?? const []).map(_mediaItemFromMap).toList();
    } catch (e) {
      debugPrint('[cloudstream] search failed for $name: $e');
      return const [];
    }
  }

  /// Status-reporting search for the source-health feature. The plain [search]
  /// above swallows errors to `[]`, so a caller can't tell a timed-out / broken
  /// source from an honest empty result. This routes to the native `searchStatus`
  /// handler, which returns `{items, error?}` — `error` is "timeout" / "missing"
  /// / a message when the source failed, absent when it responded (even with 0
  /// hits). The CF solver stays suppressed natively (searchDepth), like search.
  /// Throws on a hard channel failure so callers record it as an error.
  Future<({List<MediaItem> items, String? error})> searchWithStatus(
    String query,
  ) async {
    if (!Platform.isAndroid) return (items: const <MediaItem>[], error: null);
    final raw = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
      'searchStatus',
      {'name': hostKey, 'query': query},
    );
    final m = _asMap(raw);
    final items =
        (m['items'] as List?)?.map(_mediaItemFromMap).toList() ??
        const <MediaItem>[];
    final error = (m['error'] as String?)?.isNotEmpty == true
        ? m['error'] as String
        : null;
    return (items: items, error: error);
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
      'name': hostKey,
      'url': url,
      // Anime sources key episodes by Sub/Dub; the native side returns the
      // requested category's list (the Sub/Dub toggle re-fetches with 'dub').
      'category': category,
    });
    final m = _asMap(raw);
    final episodesRaw = m['episodes'];
    final episodes = <Episode>[];
    if (episodesRaw is List) {
      for (final e in episodesRaw) {
        episodes.add(_episodeFromMap(_asMap(e)));
      }
    }
    final csType = m['type'] as String?;
    final ids = _parseSyncIds(m['syncData']);
    return MediaDetail(
      id: (m['url'] ?? url).toString(),
      title: (m['name'] ?? '').toString(),
      cover: (m['posterUrl'] as String?),
      url: (m['url'] ?? url).toString(),
      description: (m['plot'] as String?),
      episodes: episodes,
      year: (m['year'] as num?)?.toInt().toString(),
      type: _typeFromCsType(csType) ?? _providerType,
      sourceId: sourceId,
      // Sub/Dub episode counts → drive the app's Sub/Dub toggle (download +
      // player). Both are reported regardless of the requested category.
      subCount: (m['subCount'] as num?)?.toInt(),
      dubCount: (m['dubCount'] as num?)?.toInt(),
      // Ids drive tracker sync (AniList/MAL/Simkl) + id-based Cast/Relations.
      malId: ids.malId,
      tmdbId: ids.tmdbId,
      tmdbIsTv: _csTypeIsTv(csType),
      imdbId: ids.imdbId,
      // Cast/Relations straight from the provider (works without ids).
      castMembers: _castFrom(m['actors']),
      relations: _relationsFrom(m['recommendations']),
    );
  }

  /// Extracts the ids a CloudStream provider stamped into `syncData`. Keys vary
  /// by version (e.g. `mal`, `anilist`, `imdb`, `tmdb`), so match by substring.
  ({int? malId, int? tmdbId, String? imdbId}) _parseSyncIds(dynamic raw) {
    int? malId;
    int? tmdbId;
    String? imdbId;
    if (raw is Map) {
      raw.forEach((k, v) {
        final key = k.toString().toLowerCase();
        final val = v?.toString() ?? '';
        if (val.isEmpty) return;
        if (key.contains('imdb')) {
          imdbId = val;
        } else if (key.contains('tmdb')) {
          tmdbId = int.tryParse(val) ?? tmdbId;
        } else if (key.contains('anilist')) {
          // No anilist-id field on MediaDetail; AniList sync keys off malId.
        } else if (key.contains('mal')) {
          malId = int.tryParse(val) ?? malId;
        }
      });
    }
    return (malId: malId, tmdbId: tmdbId, imdbId: imdbId);
  }

  /// True for CloudStream types that map to TMDB's `tv` namespace (series),
  /// false for movies — picks the right Simkl/TMDB lookup for [MediaDetail].
  bool _csTypeIsTv(String? csType) {
    switch (csType) {
      case 'Movie':
      case 'AnimeMovie':
      case 'Torrent':
        return false;
      default:
        return true; // TvSeries, Anime, OVA, Cartoon, AsianDrama, Documentary…
    }
  }

  List<CastMember> _castFrom(dynamic raw) {
    if (raw is! List) return const [];
    final out = <CastMember>[];
    for (final a in raw) {
      final am = _asMap(a);
      final name = (am['name'] ?? '').toString();
      if (name.isEmpty) continue;
      out.add(
        CastMember(
          name: name,
          role: (am['role'] as String?)?.isNotEmpty == true
              ? am['role'] as String
              : null,
          photo: (am['image'] as String?)?.isNotEmpty == true
              ? am['image'] as String
              : null,
        ),
      );
    }
    return out;
  }

  List<MediaRelation> _relationsFrom(dynamic raw) {
    if (raw is! List) return const [];
    final out = <MediaRelation>[];
    for (final r in raw) {
      final rm = _asMap(r);
      final title = (rm['name'] ?? '').toString();
      if (title.isEmpty) continue;
      out.add(
        MediaRelation(
          title: title,
          cover: (rm['posterUrl'] as String?),
          relation: 'Recommended',
        ),
      );
    }
    return out;
  }

  @override
  Future<List<Episode>> getEpisodes(
    String url, {
    String category = 'sub',
  }) async {
    final detail = await getDetail(url, category: category);
    return detail.episodes;
  }

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
      'loadLinks',
      {'name': hostKey, 'data': episodeUrl, 'fast': fast},
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
        // Torrents / magnet links now stream via the native engine (Phase 1),
        // so keep them — tagged as torrent so the player routes them there.
        final lower = streamUrl.toLowerCase();
        final isTorrent =
            lower.startsWith('magnet:') || lower.endsWith('.torrent');

        final quality = (sm['quality'] as num?)?.toInt() ?? 0;
        final isM3u8 = sm['isM3u8'] == true;
        var referer = (sm['referer'] ?? '').toString();
        // Some Cloudflare-fronted CDNs (e.g. mewstream/nekostream behind the
        // MegaPlay/Vidtube embeds) run a WAF rule that 403s a bare-origin
        // Referer ("https://host") but serves 200 for the "https://host/" a
        // real browser always sends. Normalize a scheme+host-only Referer to
        // include that trailing slash so these HLS streams play. Harmless for
        // every other source (servers treat the two forms identically).
        if (RegExp(r'^https?://[^/]+$').hasMatch(referer)) {
          referer = '$referer/';
        }
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
            container: isTorrent
                ? SourceContainer.torrent
                : (isM3u8 ? SourceContainer.hls : SourceContainer.mp4),
            // A magnet needs no HTTP headers.
            headers: (isTorrent || headers.isEmpty) ? null : headers,
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

  /// In-flight getHome, shared so concurrent callers (e.g. the home screen's
  /// initState load AND the source-switch listener firing for the same source)
  /// collapse into ONE native fetch instead of two.
  Future<List<HomeSection>?>? _inflightHome;

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) {
    return _inflightHome ??= _fetchHome().whenComplete(
      () => _inflightHome = null,
    );
  }

  /// Static so it can run inside a `compute` isolate (off the UI thread).
  static List<dynamic> _decodeJsonList(String s) =>
      jsonDecode(s) as List<dynamic>;

  Future<List<HomeSection>?> _fetchHome() async {
    if (!Platform.isAndroid) return null;
    // Native returns the feed as a JSON STRING (serialized on its background
    // thread). Handing Flutter a nested List<Map> would make the platform
    // channel encode it on the UI thread — which skips frames on big feeds like
    // MovieBox. Decode it OFF the UI thread (compute) when it's large.
    final jsonStr = await _csChannel.invokeMethod<String>('getHome', {
      'name': hostKey,
    });
    if (jsonStr == null || jsonStr.isEmpty || jsonStr == '[]') return null;
    final List<dynamic> raw = jsonStr.length > 20000
        ? await compute(_decodeJsonList, jsonStr)
        : _decodeJsonList(jsonStr);
    if (raw.isEmpty) return null;
    final sections = <HomeSection>[];
    for (final r in raw) {
      final m = _asMap(r);
      final items =
          (m['items'] as List?)?.map(_mediaItemFromMap).toList() ??
          const <MediaItem>[];
      if (items.isEmpty) continue;
      // The native host (getHome) stamps each row with the mainPage category
      // identifiers so the "See all" grid can page further. When they're
      // absent (older native build) leave `more` null → the row stays a fixed
      // list, exactly as before.
      final catName = (m['categoryName'] as String?) ?? '';
      final catData = (m['categoryData'] as String?) ?? '';
      final more = catName.isEmpty
          ? null
          : BrowseMore(
              sourceId: sourceId,
              kind: 'cs_mainpage',
              // Pack name + data with a single space, split back in
              // [browseMainPage]. CloudStream category names never contain a
              // space that would confuse the split — data may, so we split on
              // the FIRST space only.
              categoryId: '$catName $catData',
            );
      sections.add(
        HomeSection(
          title: (m['title'] ?? '').toString(),
          items: items,
          more: more,
        ),
      );
    }
    return sections.isEmpty ? null : sections;
  }

  /// One further page of a CloudStream `mainPage` category, for the "See all"
  /// browse grid's infinite scroll. [categoryId] is the packed `"<name> <data>"`
  /// produced in [_fetchHome]; [page] is 1-based. Android-only; returns `[]` on
  /// any error (never throws) so a failed page just stops the scroll.
  Future<List<MediaItem>> browseMainPage(String categoryId, int page) async {
    if (!Platform.isAndroid) return const [];
    // Split on the FIRST space: name is a single token, data may itself contain
    // spaces (it's an opaque category url/path).
    final sep = categoryId.indexOf(' ');
    final name = sep < 0 ? categoryId : categoryId.substring(0, sep);
    final data = sep < 0 ? '' : categoryId.substring(sep + 1);
    try {
      final raw = await _csChannel.invokeMethod<List<dynamic>>(
        'getMainPagePaged',
        {'apiName': hostKey, 'name': name, 'data': data, 'page': page},
      );
      return (raw ?? const []).map(_mediaItemFromMap).toList();
    } catch (e) {
      debugPrint('[cloudstream] browseMainPage failed for $name p$page: $e');
      return const [];
    }
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

/// One installable plugin from a repo's catalog (metadata only — installing it
/// downloads the `.cs3`). `id` is the file id ("internalName@version") used by
/// the host for download/grouping.
class CsPluginMeta {
  const CsPluginMeta({
    required this.internalName,
    required this.name,
    required this.url,
    required this.version,
    this.language,
    this.tvTypes = const [],
    this.iconUrl,
  });

  final String internalName;
  final String name;
  final String url; // the .cs3 download URL
  final int version;
  final String? language;
  final List<String> tvTypes;
  final String? iconUrl;

  String get id => '$internalName@$version';

  factory CsPluginMeta.fromMap(Map<dynamic, dynamic> m) => CsPluginMeta(
    internalName: (m['internalName'] ?? '').toString(),
    name: (m['name'] ?? m['internalName'] ?? '').toString(),
    url: (m['url'] ?? '').toString(),
    version: (m['version'] is num) ? (m['version'] as num).toInt() : 1,
    language: (m['language'] as String?)?.isNotEmpty == true
        ? m['language'] as String
        : null,
    tvTypes: (m['tvTypes'] is List)
        ? [for (final t in m['tvTypes'] as List) '$t']
        : const [],
    iconUrl: (m['iconUrl'] as String?)?.isNotEmpty == true
        ? m['iconUrl'] as String
        : null,
  );

  Map<String, dynamic> toJson() => {
    'internalName': internalName,
    'name': name,
    'url': url,
    'version': version,
    'language': language,
    'tvTypes': tvTypes,
    'iconUrl': iconUrl,
  };
}

/// An available update for an installed CloudStream plugin: the repo-scoped
/// plugin identity plus its installed vs online version. Produced by the
/// READ-ONLY [CloudStreamManager.checkRepoUpdates] native check (no download).
class CsUpdate {
  const CsUpdate({
    required this.internalName,
    required this.name,
    required this.url,
    required this.installedVersion,
    required this.onlineVersion,
  });

  final String internalName;
  final String name;
  final String url; // the NEW .cs3 download URL
  final int installedVersion;
  final int onlineVersion;

  factory CsUpdate.fromMap(Map<dynamic, dynamic> m) => CsUpdate(
    internalName: (m['internalName'] ?? '').toString(),
    name: (m['name'] ?? m['internalName'] ?? '').toString(),
    url: (m['url'] ?? '').toString(),
    installedVersion: (m['installedVersion'] is num)
        ? (m['installedVersion'] as num).toInt()
        : 0,
    onlineVersion: (m['onlineVersion'] is num)
        ? (m['onlineVersion'] as num).toInt()
        : 0,
  );
}

/// A persisted CloudStream repo, its installable catalog, and the loaded sources
/// that belong to it. Built by [CloudStreamManager.repoGroups] for the grouped
/// Providers/CloudStream UI.
///   * [url]    — the repo manifest URL (empty for the synthetic "Other" group).
///   * [name]   — the repo's advertised name.
///   * [owner]  — parsed from the URL (GitHub owner, else the host).
///   * [catalog]— every plugin the repo advertises (install one by one).
///   * [sources]— the loaded providers that belong to this repo.
class CsRepoGroup {
  const CsRepoGroup({
    required this.url,
    required this.name,
    required this.owner,
    required this.catalog,
    required this.sources,
  });

  final String url;
  final String name;
  final String owner;
  final List<CsPluginMeta> catalog;
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
  static const String _disabledKey = 'disabled';
  static const String _notifyUpdatesKey = 'notifyUpdates';

  /// Opens the persisted-repo box. Safe on every platform (only the channel
  /// calls are Android-gated). Must be called before constructing the manager.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  final Map<String, CloudStreamProvider> _providers = {};

  /// In-memory mirror of the persisted repo list: each entry is
  /// `{url, name, files:[...]}`. Loaded on [loadInstalled], upserted on
  /// [addRepo].
  final List<Map<String, dynamic>> _repos = [];

  /// sourceIds the user has toggled off. Persisted under [_disabledKey].
  final Set<String> _disabled = {};

  /// Repo url → its currently-known available plugin updates (from the last
  /// [checkRepoUpdates] / [checkAllUpdates]). Drives the "update available"
  /// badges and counts; cleared per-repo after a successful update. In-memory
  /// only — re-derived by the next check.
  final Map<String, List<CsUpdate>> _updates = {};

  /// When [checkAllUpdates] last ran, to debounce repeat checks (launch +
  /// manual taps) within [_updatesTtl].
  DateTime? _lastUpdateCheck;
  static const Duration _updatesTtl = Duration(minutes: 30);

  Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// Total installed plugins (across all repos) with an available update.
  int get updateCount =>
      _updates.values.fold(0, (sum, list) => sum + list.length);

  /// Whether any installed plugin has an available update.
  bool get hasUpdates => updateCount > 0;

  /// The known available updates for a repo (empty when none / unchecked).
  List<CsUpdate> updatesFor(String repoUrl) =>
      List.unmodifiable(_updates[repoUrl] ?? const []);

  /// The available update for a specific installed plugin, or null.
  CsUpdate? updateFor(String internalName, String repoUrl) {
    for (final u in _updates[repoUrl] ?? const <CsUpdate>[]) {
      if (u.internalName == internalName) return u;
    }
    return null;
  }

  /// Whether to post a system notification when installed sources have updates
  /// (the launch check). Default true. Persisted in [boxName].
  bool get notifyUpdates =>
      _box?.get(_notifyUpdatesKey, defaultValue: true) as bool? ?? true;

  /// Toggle the launch "source updates available" notification (persisted).
  Future<void> setNotifyUpdates(bool value) async {
    await _box?.put(_notifyUpdatesKey, value);
    notifyListeners();
  }

  /// All installed CloudStream providers (enabled + disabled — for the
  /// Providers management UI).
  List<CloudStreamProvider> get all => _providers.values.toList();

  /// Only the enabled providers — for the home / active-source pickers.
  List<CloudStreamProvider> get enabled =>
      _providers.values.where((p) => isEnabled(p.sourceId)).toList();

  /// Provider for a `cs:<name>` source id, or null when not installed.
  BaseProvider? get(String sourceId) => _providers[sourceId];

  /// Whether a repo with this exact [url] has already been added (used to show
  /// an "Added" state for recommended repos instead of a duplicate "Add").
  bool hasRepo(String url) =>
      _repos.any((r) => (r['url'] ?? '').toString() == url);

  /// Resolve a provider for [sourceId], falling back to the provider's
  /// repo/version-agnostic IDENTITY (its internalName / name, ignoring the
  /// `@version@repoTag` suffix) when the exact tagged id isn't installed. Lets a
  /// Watch Together room created on one install resolve on another that has the
  /// SAME provider from a different repo or version. Exact match runs first, so
  /// normal playback is unaffected — the name fallback only triggers when the
  /// exact id is missing.
  BaseProvider? resolveCompatible(String sourceId) {
    final exact = _providers[sourceId];
    if (exact != null) return exact;
    final wanted = _identity(sourceId);
    if (wanted.isEmpty) return null;
    CloudStreamProvider? fallback;
    for (final p in _providers.values) {
      final ids = <String>{
        _identity(p.sourceId),
        if (p.sourcePlugin != null && p.sourcePlugin!.isNotEmpty)
          p.sourcePlugin!.split('@').first.toLowerCase(),
        p.name.toLowerCase(),
      };
      if (!ids.contains(wanted)) continue;
      if (isEnabled(p.sourceId)) return p; // prefer an enabled match
      fallback ??= p;
    }
    return fallback;
  }

  /// Repo/version-agnostic identity token of a `cs:` source id — the
  /// internalName (first `@`-segment of the plugin id) or the bare name.
  static String _identity(String sourceId) {
    final body = sourceId.startsWith('cs:') ? sourceId.substring(3) : sourceId;
    final at = body.indexOf('@');
    return (at >= 0 ? body.substring(0, at) : body).toLowerCase();
  }

  /// The origin repo's display name for an installed CS source, or null when it
  /// isn't attributable to a persisted repo (e.g. the synthetic "Other" group).
  /// Used to show "which repo" a source came from (detail screen, etc.).
  String? repoNameForSourceId(String sourceId) {
    for (final g in repoGroups) {
      if (g.name.isEmpty) continue;
      if (g.sources.any((s) => s.sourceId == sourceId)) return g.name;
    }
    return null;
  }

  /// Whether a source is enabled (not toggled off by the user).
  bool isEnabled(String sourceId) => !_disabled.contains(sourceId);

  /// Toggle a source on/off (persisted). Disabled sources stay listed in the
  /// Providers screen but are hidden from the source pickers.
  Future<void> setEnabled(String sourceId, bool value) async {
    if (value) {
      _disabled.remove(sourceId);
    } else {
      _disabled.add(sourceId);
    }
    _box?.put(_disabledKey, _disabled.toList());
    notifyListeners();
  }

  /// Remove a repo entirely: unregister + delete its cached `.cs3`s natively,
  /// drop the persisted record, and rebuild. No-op channel on non-Android.
  Future<void> deleteRepo(String url) async {
    final repo = _repos.firstWhere(
      (r) => (r['url'] ?? '').toString() == url,
      orElse: () => const {},
    );
    final files = <String>[
      for (final f in (repo['files'] as List? ?? const [])) '$f',
    ];
    if (Platform.isAndroid && files.isNotEmpty) {
      try {
        final raw = await _csChannel.invokeMethod<List<dynamic>>('deleteRepo', {
          'files': files,
        });
        _rebuildFrom(raw);
      } catch (e) {
        debugPrint('[cloudstream] deleteRepo failed: $e');
      }
    }
    _repos.removeWhere((r) => (r['url'] ?? '').toString() == url);
    _persistRepos();
    notifyListeners();
  }

  /// Update a repo: re-fetch its manifest and re-download + load ONLY the
  /// installed plugins whose version changed (already-current ones are skipped
  /// natively). Updates the persisted record + rebuilds. Returns the number of
  /// plugins ACTUALLY updated (0 = already up to date). No-op on non-Android.
  Future<int> updateRepo(String url) async {
    if (!Platform.isAndroid) return 0;
    try {
      final repo = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
        'updateRepo',
        {'url': url},
      );
      _upsertRepo(repo, fallbackUrl: url);
      // Native returns the refreshed source list (only installed plugins are
      // re-loaded); rebuild from it.
      final sources = (repo?['sources'] as List?);
      _rebuildFrom(sources);
      // This repo's plugins are now current — drop its pending updates.
      _updates.remove(url);
      notifyListeners();
      return (repo?['updated'] as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('[cloudstream] updateRepo failed: $e');
      rethrow;
    }
  }

  /// READ-ONLY: re-fetch [url]'s catalog natively and record which installed
  /// plugins have a newer version online — WITHOUT downloading anything (no disk
  /// or plugin-state mutation). Updates [_updates] for this repo + notifies.
  /// Returns the outdated list (empty off Android or on any error — never throws).
  Future<List<CsUpdate>> checkRepoUpdates(String url) async {
    if (!Platform.isAndroid || url.isEmpty) return const [];
    try {
      final res = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
        'checkRepoUpdates',
        {'url': url},
      );
      final raw = res?['outdated'];
      final list = <CsUpdate>[
        if (raw is List)
          for (final m in raw)
            if (m is Map) CsUpdate.fromMap(m),
      ];
      if (list.isEmpty) {
        _updates.remove(url);
      } else {
        _updates[url] = list;
      }
      notifyListeners();
      return list;
    } catch (e) {
      debugPrint('[cloudstream] checkRepoUpdates failed: $e');
      return const [];
    }
  }

  /// Checks EVERY added repo for plugin updates (read-only). Debounced to once
  /// per [_updatesTtl] unless [force]. Returns the total number of updates found.
  /// Best-effort — a repo that fails to check is skipped. No-op off Android.
  Future<int> checkAllUpdates({bool force = false}) async {
    if (!Platform.isAndroid) return 0;
    final last = _lastUpdateCheck;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _updatesTtl) {
      return updateCount;
    }
    _lastUpdateCheck = DateTime.now();
    final urls = <String>[
      for (final r in _repos)
        if ((r['url'] ?? '').toString().isNotEmpty) (r['url']).toString(),
    ];
    for (final url in urls) {
      await checkRepoUpdates(url);
    }
    return updateCount;
  }

  /// Update ONE installed plugin to its available newer version (download + load
  /// the new `.cs3`, repo-scoped via [repoUrl]). On success the plugin is dropped
  /// from [_updates]. Rebuilds + notifies. No-op off Android; rethrows on failure.
  Future<void> updatePlugin(CsUpdate update, {required String repoUrl}) async {
    if (!Platform.isAndroid) return;
    try {
      final raw = await _csChannel.invokeMethod<List<dynamic>>('updatePlugin', {
        'url': update.url,
        'internalName': update.internalName,
        'version': update.onlineVersion,
        'repoUrl': repoUrl,
      });
      _rebuildFrom(raw);
      final list = _updates[repoUrl];
      if (list != null) {
        list.removeWhere((u) => u.internalName == update.internalName);
        if (list.isEmpty) _updates.remove(repoUrl);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[cloudstream] updatePlugin failed: $e');
      rethrow;
    }
  }

  /// The loaded sources grouped by their origin repo (for the grouped UI).
  ///
  /// For each persisted repo, [CsRepoGroup.sources] are the loaded providers
  /// whose `sourcePlugin` file id is in that repo's `files`
  /// (case-insensitive). Any loaded providers not matched to a persisted repo
  /// are collected into a trailing synthetic "Other" group (only when present)
  /// — this covers sources loaded from the host cache before persistence.
  List<CsRepoGroup> get repoGroups {
    final groups = <CsRepoGroup>[];
    final claimed = <String>{}; // sourceIds already placed in a repo group

    for (final repo in _repos) {
      final repoUrl = (repo['url'] ?? '').toString();
      final repoTag = _csRepoTag(repoUrl);
      final files = <String>{};
      final rawFiles = repo['files'];
      if (rawFiles is List) {
        for (final f in rawFiles) {
          files.add('$f');
        }
      }
      final catalog = _catalogOf(repo);
      // A repo's plugins by internalName (catalog + legacy file ids) — used to
      // attribute LEGACY (un-tagged) sources, where we can't tell repos apart.
      final internalNames = <String>{
        for (final p in catalog) p.internalName,
        for (final f in files) f.split('@').first,
      };
      final sources = <CloudStreamProvider>[];
      for (final p in _providers.values) {
        final sp = p.sourcePlugin;
        if (sp == null || claimed.contains(p.sourceId)) continue;
        // Tagged file id → belongs to EXACTLY the repo whose url hashes to its
        // tag, so a same-named plugin from two repos no longer lands in both
        // groups (which made one toggle look like it moved the other). Legacy
        // un-tagged ids fall back to internalName matching.
        final tagged = '@'.allMatches(sp).length >= 2;
        final matches = tagged
            ? sp.endsWith('@$repoTag')
            : internalNames.contains(sp.split('@').first);
        if (matches) {
          sources.add(p);
          claimed.add(p.sourceId);
        }
      }
      groups.add(
        CsRepoGroup(
          url: (repo['url'] ?? '').toString(),
          name: (repo['name'] ?? '').toString(),
          owner: _ownerOf((repo['url'] ?? '').toString()),
          catalog: catalog,
          sources: sources,
        ),
      );
    }

    final orphans = _providers.values
        .where((p) => !claimed.contains(p.sourceId))
        .toList();
    if (orphans.isNotEmpty) {
      groups.add(
        CsRepoGroup(
          url: '',
          name: 'Other',
          owner: '',
          catalog: const [],
          sources: orphans,
        ),
      );
    }
    return groups;
  }

  /// The parsed catalog for a persisted repo record (empty if not fetched yet).
  List<CsPluginMeta> _catalogOf(Map<String, dynamic> repo) {
    final raw = repo['catalog'];
    if (raw is! List) return const [];
    return [
      for (final m in raw)
        if (m is Map) CsPluginMeta.fromMap(m),
    ];
  }

  /// Whether [internalName] from the repo at [repoUrl] is installed. With
  /// [repoUrl] the check is REPO-SCOPED — this repo's tagged `.cs3` file or a
  /// legacy un-tagged one — so a same-named plugin in ANOTHER repo stays its own
  /// separately (un)installable entry (that's what lets you install the second
  /// copy). Without [repoUrl] it's the legacy name-only check.
  bool isPluginInstalled(String internalName, {String? repoUrl}) {
    final tag = (repoUrl != null && repoUrl.isNotEmpty)
        ? _csRepoTag(repoUrl)
        : null;
    return _providers.values.any((p) {
      final sp = p.sourcePlugin;
      if (sp == null || sp.split('@').first != internalName) return false;
      if (tag == null) return true; // legacy: any same-name install counts
      // this repo's tagged id, or a legacy un-tagged "name@version" (one '@')
      return sp.endsWith('@$tag') || '@'.allMatches(sp).length == 1;
    });
  }

  /// Installs one plugin from a repo's catalog (download + load). [repoUrl] is
  /// the repository the user added — the cache file is tagged with it so the
  /// SAME plugin installed from two repos lands in two files. Rebuilds. No-op
  /// off Android.
  Future<void> installPlugin(CsPluginMeta plugin, {String repoUrl = ''}) async {
    if (!Platform.isAndroid) return;
    try {
      final raw = await _csChannel
          .invokeMethod<List<dynamic>>('installPlugin', {
            'url': plugin.url,
            'internalName': plugin.internalName,
            'version': plugin.version,
            'repoUrl': repoUrl,
          });
      _rebuildFrom(raw);
      notifyListeners();
    } catch (e) {
      debugPrint('[cloudstream] installPlugin failed: $e');
      rethrow;
    }
  }

  /// Uninstalls one plugin and its sources — repo-scoped via [repoUrl], so a
  /// same-named plugin from another repo is left intact. Rebuilds.
  Future<void> uninstallPlugin(
    CsPluginMeta plugin, {
    String repoUrl = '',
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final raw = await _csChannel.invokeMethod<List<dynamic>>(
        'uninstallPlugin',
        {
          'internalName': plugin.internalName,
          'url': plugin.url,
          'repoUrl': repoUrl,
        },
      );
      _rebuildFrom(raw);
      notifyListeners();
    } catch (e) {
      debugPrint('[cloudstream] uninstallPlugin failed: $e');
      rethrow;
    }
  }

  /// Lazily fetches a repo's catalog if it isn't loaded yet (e.g. a repo added
  /// before per-plugin install existed). Best-effort; safe to call repeatedly.
  Future<void> ensureCatalog(String url) async {
    if (!Platform.isAndroid || url.isEmpty) return;
    final repo = _repos.firstWhere(
      (r) => (r['url'] ?? '').toString() == url,
      orElse: () => const {},
    );
    if (repo.isEmpty) return;
    if (_catalogOf(Map<String, dynamic>.from(repo)).isNotEmpty) return;
    try {
      final info = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
        'addRepo',
        {'url': url},
      );
      _upsertRepo(info, fallbackUrl: url);
      notifyListeners();
    } catch (e) {
      debugPrint('[cloudstream] ensureCatalog failed: $e');
    }
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

  /// Adds a CloudStream repo by [url], fetching + persisting its catalog. Does
  /// NOT install anything — the user installs plugins one by one via
  /// [installPlugin]. Returns the number of installable plugins the repo
  /// advertises. No-op on non-Android.
  Future<int> addRepo(String url) async {
    if (!Platform.isAndroid) return 0;
    try {
      final repo = await _csChannel.invokeMethod<Map<dynamic, dynamic>>(
        'addRepo',
        {'url': url},
      );
      _upsertRepo(repo, fallbackUrl: url);
      notifyListeners();
      final added = _repos.firstWhere(
        (r) => (r['url'] ?? '').toString() == url,
        orElse: () => const {},
      );
      return _catalogOf(Map<String, dynamic>.from(added)).length;
    } catch (e) {
      debugPrint('[cloudstream] addRepo failed: $e');
      rethrow;
    }
  }

  /// Upserts a `{name, url, plugins}` repo map (the native catalog response) into
  /// the persisted list, replacing any existing entry with the same url. Keeps
  /// `files` as the UNION of any legacy file ids and the catalog's file ids so
  /// grouping/delete keep working across the migration. Tolerant of missing keys.
  void _upsertRepo(Map<dynamic, dynamic>? repo, {required String fallbackUrl}) {
    final m = repo == null ? const {} : Map<String, dynamic>.from(repo);
    final repoUrl = (m['url'] ?? fallbackUrl).toString();

    final catalog = <Map<String, dynamic>>[];
    final rawPlugins = m['plugins'];
    if (rawPlugins is List) {
      for (final p in rawPlugins) {
        if (p is Map) catalog.add(CsPluginMeta.fromMap(p).toJson());
      }
    }

    // Preserve any legacy/installed file ids from the existing record, then add
    // the catalog's current file ids.
    final files = <String>{};
    final existing = _repos.firstWhere(
      (r) => (r['url'] ?? '').toString() == repoUrl,
      orElse: () => const {},
    );
    final exFiles = existing['files'];
    if (exFiles is List) {
      for (final f in exFiles) {
        files.add('$f');
      }
    }
    final repoTag = _csRepoTag(repoUrl); // tag derived from THIS repo's url
    for (final p in catalog) {
      final base = '${p['internalName']}@${p['version']}';
      files.add(
        base,
      ); // legacy un-tagged id (installs from before per-repo tagging)
      files.add('$base@$repoTag'); // current tagged id (this repo's copy)
    }
    // If the native response carried explicit file ids (legacy), keep them too.
    final rawFiles = m['files'];
    if (rawFiles is List) {
      for (final f in rawFiles) {
        files.add('$f');
      }
    }

    final entry = <String, dynamic>{
      'url': repoUrl,
      'name': (m['name'] ?? existing['name'] ?? '').toString(),
      'files': files.toList(),
      // Keep the prior catalog if the new response has none (defensive).
      'catalog': catalog.isNotEmpty
          ? catalog
          : (existing['catalog'] ?? const []),
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
  /// `{url, name, files:[String...]}`.
  void _loadRepos() {
    _repos.clear();
    _disabled.clear();
    final dis = _box?.get(_disabledKey);
    if (dis is List) {
      for (final d in dis) {
        _disabled.add('$d');
      }
    }
    final raw = _box?.get(_reposKey);
    if (raw is! List) return;
    for (final r in raw) {
      if (r is! Map) continue;
      final m = Map<String, dynamic>.from(r);
      final files = <String>[];
      final rawFiles = m['files'];
      if (rawFiles is List) {
        for (final f in rawFiles) {
          files.add('$f');
        }
      }
      final catalog = <Map<String, dynamic>>[];
      final rawCatalog = m['catalog'];
      if (rawCatalog is List) {
        for (final c in rawCatalog) {
          if (c is Map) catalog.add(Map<String, dynamic>.from(c));
        }
      }
      _repos.add({
        'url': (m['url'] ?? '').toString(),
        'name': (m['name'] ?? '').toString(),
        'files': files,
        'catalog': catalog,
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
      _migrateLegacyRepo();
    } catch (e) {
      debugPrint('[cloudstream] listSources failed: $e');
    }
    notifyListeners();
  }

  /// One-time migration for repos saved before file-based attribution existed:
  /// if there's exactly one persisted repo and it has no `files`, attribute all
  /// loaded sources to it (so they group under the real repo + get the ⋮ menu
  /// instead of falling into "Other"). Multi-repo legacy installs re-add to fix.
  void _migrateLegacyRepo() {
    if (_repos.length != 1) return;
    final files = _repos[0]['files'];
    if (files is List && files.isNotEmpty) return;
    final stamped = _providers.values
        .map((p) => p.sourcePlugin)
        .whereType<String>()
        .toList();
    if (stamped.isEmpty) return;
    _repos[0]['files'] = stamped;
    _persistRepos();
  }

  void _rebuildFrom(List<dynamic>? raw) {
    _providers.clear();
    final all = <Map<String, dynamic>>[
      for (final e in raw ?? const [])
        if (e is Map) Map<String, dynamic>.from(e),
    ];
    // Collapse stale duplicates: the same plugin (same internalName + same repo
    // tag) left on disk at multiple versions — e.g. an update whose old `.cs3`
    // wasn't cleaned up — would otherwise load twice and show as identical twins
    // in the picker. Keep only the HIGHEST version per (internalName, tag).
    // Entries without a file id (unique `cs:<name>` sources) pass through
    // untouched; a different repo (different tag) keeps its own copy, so
    // genuinely-distinct same-named sources from different repos still both show.
    final byIdentity = <String, Map<String, dynamic>>{};
    final entries = <Map<String, dynamic>>[];
    for (final m in all) {
      final sp = (m['sourcePlugin'] as String?) ?? '';
      if (sp.isEmpty) {
        entries.add(m);
        continue;
      }
      final parts = sp.split('@');
      final internal = parts.isNotEmpty ? parts[0] : sp;
      final ver = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
      final tag = parts.length > 2 ? parts.sublist(2).join('@') : '';
      // Group by the RESOLVED repo (what the user sees as the label), so two
      // copies that both read e.g. "(Phisher Repo)" collapse even when a past
      // update left them under slightly different file tags. Falls back to the
      // raw tag when no persisted repo claims the file — a genuinely different
      // repo resolves to a different label and is kept separately.
      final repo = _repoLabelFor(sp) ?? tag;
      final key = '$internal|$repo';
      final existing = byIdentity[key];
      if (existing == null) {
        byIdentity[key] = m;
      } else {
        final eParts = ((existing['sourcePlugin'] as String?) ?? '').split('@');
        final eVer = eParts.length > 1 ? (int.tryParse(eParts[1]) ?? 0) : 0;
        if (ver > eVer) byIdentity[key] = m; // keep the newer of the two
      }
    }
    entries.addAll(byIdentity.values);
    // Count display-name occurrences first, so ONLY genuine collisions get the
    // file-id identity. Unique-named sources keep their `cs:<name>` id (and their
    // persisted enable/health/history state) completely untouched.
    final nameCounts = <String, int>{};
    for (final m in entries) {
      final n = (m['name'] ?? '').toString();
      if (n.isNotEmpty) nameCounts[n] = (nameCounts[n] ?? 0) + 1;
    }
    for (final m in entries) {
      final name = (m['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final types = <String>[];
      final rawTypes = m['types'];
      if (rawTypes is List) {
        for (final t in rawTypes) {
          types.add('$t');
        }
      }
      final sourcePlugin = (m['sourcePlugin'] as String?);
      // Disambiguate only when another installed source shares this name AND we
      // have a unique file id to identify it by.
      final dup =
          (nameCounts[name] ?? 0) > 1 &&
          sourcePlugin != null &&
          sourcePlugin.isNotEmpty;
      final provider = CloudStreamProvider(
        name: name,
        lang: (m['lang'] ?? '').toString(),
        types: types,
        sourcePlugin: sourcePlugin,
        disambiguate: dup,
        repoLabel: dup ? _repoLabelFor(sourcePlugin) : null,
      );
      _providers[provider.sourceId] = provider;
    }
  }

  /// A short label for the repo owning [sourcePlugin] (matched via the persisted
  /// repo records' file ids), shown to tell same-named sources apart. Null when
  /// no persisted repo claims it — the UI then falls back to the file tag.
  String? _repoLabelFor(String? sourcePlugin) {
    if (sourcePlugin == null || sourcePlugin.isEmpty) return null;
    // Tagged file id ("name@version@tag"): the owning repo is the ONE whose url
    // hashes to that tag — not just any repo that lists the name. This is what
    // makes a phisher install read "Phisher", not whichever repo sorts first.
    if ('@'.allMatches(sourcePlugin).length >= 2) {
      final tag = sourcePlugin.substring(sourcePlugin.lastIndexOf('@') + 1);
      for (final r in _repos) {
        if (_csRepoTag((r['url'] ?? '').toString()) == tag) {
          final nm = (r['name'] ?? '').toString();
          if (nm.isNotEmpty) return nm;
        }
      }
      return null;
    }
    // Legacy un-tagged id: best-effort first repo that lists it.
    for (final r in _repos) {
      final files = r['files'];
      if (files is List && files.any((f) => '$f' == sourcePlugin)) {
        final nm = (r['name'] ?? '').toString();
        if (nm.isNotEmpty) return nm;
      }
    }
    return null;
  }
}
