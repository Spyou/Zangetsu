import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import '../provider/base_provider.dart';
import 'aniyomi_filters.dart';
import 'aniyomi_source_info.dart';
import 'aniyomi_mapping.dart';

/// Shared channel — matches the name registered in [AniyomiBridge.attach].
const MethodChannel _aniChannel = MethodChannel('zangetsu/aniyomi');

/// Returns true when [provider] should be visible in source lists.
///
/// NSFW-flagged [AniyomiProvider]s are hidden when [showNsfwAniyomi] is
/// false. Non-Aniyomi providers are always visible (never filtered).
bool aniyomiNsfwVisible(
  BaseProvider provider, {
  required bool showNsfwAniyomi,
}) {
  if (provider is! AniyomiProvider) return true;
  if (!provider.info.nsfw) return true;
  return showNsfwAniyomi;
}

/// A single Aniyomi anime source wrapped as a [BaseProvider].
///
/// Constructed from an [AniyomiSourceInfo] returned by
/// [AniyomiExtensionService.listSources]; one instance per native source.
/// Identified by `'ani:<sourceId>'` so it lives alongside CloudStream (`cs:`)
/// and JS providers without collisions.
///
/// All data methods forward to the `zangetsu/aniyomi` channel, which Task 7
/// populates with `getPopular`, `getLatest`, `search`, `getDetails`,
/// `getEpisodes`, and `getVideoList`.  Until Task 7 is merged these calls
/// return `MissingPluginException`; the provider swallows them and degrades
/// gracefully to empty results.
class AniyomiProvider implements BaseProvider {
  AniyomiProvider({required this.info});

  /// The native source descriptor this provider wraps.
  final AniyomiSourceInfo info;

  @override
  String get sourceId => 'ani:${info.id}';

  @override
  String get displayName => info.name;

  /// Package name of the owning extension APK.
  String get pkg => info.pkg;

  /// Extension versionName (display).
  String get version => info.version;

  /// Extension versionCode (used for update comparisons).
  int get versionCode => info.versionCode;

  /// Headers for cover/thumbnail image requests. Many Aniyomi image hosts
  /// (e.g. AnimePahe's CDN) return 403 without a `Referer`, and a source's
  /// default headers often omit it — so fall back to the source base URL.
  Map<String, String>? get _coverHeaders {
    final h = <String, String>{...info.headers};
    final hasReferer = h.keys.any((k) => k.toLowerCase() == 'referer');
    if (!hasReferer && info.baseUrl.isNotEmpty) {
      h['Referer'] = info.baseUrl;
    }
    return h.isEmpty ? null : h;
  }

  // ── BaseProvider ────────────────────────────────────────────────────────────

  @override
  Future<ProviderInfo> getInfo() async => ProviderInfo(
    name: info.name,
    lang: info.lang,
    baseUrl: info.baseUrl,
    type: ProviderType.anime,
  );

  /// Returns two [HomeSection]s — "Popular" and "Latest" — sourced from
  /// the corresponding native calls.  Category is unused for Aniyomi.
  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
    if (!Platform.isAndroid) return null;
    final results = await Future.wait<List<MediaItem>>([
      popular(),
      _fetchLatest(),
    ]);
    final popularItems = results[0];
    final latestItems = results[1];
    final sections = <HomeSection>[
      if (popularItems.isNotEmpty)
        HomeSection(
          title: 'Popular',
          items: popularItems,
          more: BrowseMore(sourceId: sourceId, kind: 'ani_popular'),
        ),
      if (latestItems.isNotEmpty)
        HomeSection(
          title: 'Latest',
          items: latestItems,
          more: BrowseMore(sourceId: sourceId, kind: 'ani_latest'),
        ),
    ];
    return sections.isEmpty ? null : sections;
  }

  /// Returns the source's popular / trending anime page.
  /// [category] (sub/dub) is not used — Aniyomi sources do not distinguish.
  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    if (!Platform.isAndroid) return const [];
    return _invokeAnimeList('getPopular', {'sourceId': info.id, 'page': page});
  }

  /// Returns the source's latest-updated anime page. Public wrapper over
  /// [_fetchLatest] so the "See all" browse grid can page it (mirrors the
  /// already-public [popular]).
  Future<List<MediaItem>> latest({int page = 1}) => _fetchLatest(page: page);

  /// Returns the source's latest-updated anime page.
  Future<List<MediaItem>> _fetchLatest({int page = 1}) =>
      _invokeAnimeList('getLatest', {'sourceId': info.id, 'page': page});

  /// Searches the source for [query].  [category] is unused by Aniyomi sources.
  ///
  /// When [filtersJson] is provided and non-empty it is forwarded to the native
  /// bridge, which applies the selection back onto the live filter list before
  /// running the search.
  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
    String? filtersJson,
  }) async {
    if (!Platform.isAndroid) return const [];
    final args = <String, dynamic>{
      'sourceId': info.id,
      'query': query,
      'page': page,
    };
    if (filtersJson != null && filtersJson.isNotEmpty) {
      args['filters'] = filtersJson;
    }
    return _invokeAnimeList('search', args);
  }

  /// Returns the typed filter schema for this source, or an empty list when
  /// the source has no filters or the platform is not Android.
  Future<List<AniyomiFilter>> getFilters() async {
    if (!Platform.isAndroid) return const [];
    final raw = await _safeInvoke('getFilterList', {'sourceId': info.id});
    if (raw == null || raw.isEmpty) return const [];
    return AniyomiFilters.parse(raw);
  }

  /// Fetches the detail page and episode list for [url] in parallel and
  /// returns a [MediaDetail] with the episodes embedded.
  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    final fallback = MediaDetail(
      id: url,
      title: '',
      url: url,
      type: ProviderType.anime,
      sourceId: sourceId,
    );
    if (!Platform.isAndroid) return fallback;

    // Aniyomi separates getDetails (anime metadata) from getEpisodes (list).
    // Fetch both in parallel to keep latency tight.
    final res = await Future.wait<String?>([
      _safeInvoke('getDetails', {'sourceId': info.id, 'url': url}),
      _safeInvoke('getEpisodes', {'sourceId': info.id, 'url': url}),
    ]);
    final episodes = _parseEpisodeList(res[1]);
    final detailRaw = res[0];

    if (detailRaw == null || detailRaw.isEmpty) {
      return fallback.copyWith(episodes: episodes);
    }
    try {
      final j = jsonDecode(detailRaw) as Map<String, dynamic>;
      return mediaDetailFromSAnime(
        j,
        episodes,
        sourceId: sourceId,
        headers: _coverHeaders,
      );
    } catch (e) {
      debugPrint('[aniyomi] getDetail parse failed for $url: $e');
      return fallback.copyWith(episodes: episodes);
    }
  }

  /// Returns the episode list for [url].  [category] (sub/dub) is unused.
  @override
  Future<List<Episode>> getEpisodes(
    String url, {
    String category = 'sub',
  }) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _safeInvoke('getEpisodes', {
      'sourceId': info.id,
      'url': url,
    });
    return _parseEpisodeList(raw);
  }

  /// Returns the playable video sources for [episodeUrl].
  /// [fast] is accepted for interface compatibility; Aniyomi's extension API
  /// does not provide a partial-result mode.
  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _safeInvoke('getVideoList', {
      'sourceId': info.id,
      'url': episodeUrl,
    });
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(videoSourceFromVideo)
          .where((v) => v.url.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[aniyomi] getVideoList parse failed for $episodeUrl: $e');
      return const [];
    }
  }

  // ── private helpers ─────────────────────────────────────────────────────────

  /// Invokes [method] on the aniyomi channel with [args], returning the raw
  /// JSON string result.  Returns null on any error so callers degrade cleanly.
  Future<String?> _safeInvoke(String method, Map<String, dynamic> args) async {
    try {
      return await _aniChannel.invokeMethod<String>(method, args);
    } catch (e) {
      debugPrint('[aniyomi] $method(sourceId=${info.id}) failed: $e');
      return null;
    }
  }

  /// Invokes [method], decodes the JSON array result as SAnime objects, and
  /// maps each to a [MediaItem].
  Future<List<MediaItem>> _invokeAnimeList(
    String method,
    Map<String, dynamic> args,
  ) async {
    final raw = await _safeInvoke(method, args);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(
            (j) => mediaItemFromSAnime(
              j,
              sourceId: sourceId,
              headers: _coverHeaders,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('[aniyomi] $method parse failed: $e');
      return const [];
    }
  }

  /// Decodes a raw JSON array string of SEpisode objects.
  List<Episode> _parseEpisodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final eps = list
          .whereType<Map<String, dynamic>>()
          .map(episodeFromSEpisode)
          .toList();
      return sortEpisodesAscending(eps);
    } catch (_) {
      return const [];
    }
  }
}

/// Aniyomi/Tachiyomi extensions return episodes newest-first (N→1). Normalise to
/// chronological order (1→N) — like the app's other sources — so the first
/// episode plays first and next-episode navigation works. Sorts by episode
/// number when every episode has one (keeps 12 → 12.5 → 13 correct); otherwise
/// reverses the source's newest-first convention.
@visibleForTesting
List<Episode> sortEpisodesAscending(List<Episode> eps) {
  if (eps.length < 2) return eps;
  if (eps.every((e) => e.number != null)) {
    final sorted = [...eps]..sort((a, b) => a.number!.compareTo(b.number!));
    return sorted;
  }
  return eps.reversed.toList();
}
