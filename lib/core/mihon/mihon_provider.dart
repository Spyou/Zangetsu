import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/page_content.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import '../provider/base_provider.dart';
import '../provider/reading_provider.dart';
import 'mihon_cloudflare.dart';
import 'mihon_filters.dart';
import 'mihon_mapping.dart';
import 'mihon_source_info.dart';

/// Shared channel — matches the name registered in [MihonBridge.attach].
const MethodChannel _mihonChannel = MethodChannel('zangetsu/mihon');

/// Evicts the native OkHttp response cache that Mihon AND Aniyomi share, so a
/// manual refresh re-hits the source instead of serving the 10-min-cached JSON.
/// Best-effort: a missing channel (iOS) or no loaded source is a silent no-op.
Future<void> clearMihonHttpCache() async {
  try {
    await _mihonChannel.invokeMethod<String>('clearHttpCache');
  } catch (_) {
    // No channel (non-Android) or nothing loaded — nothing to clear.
  }
}

/// A single Mihon manga source wrapped as a [BaseProvider] + [ReadingProvider].
///
/// Structural twin of `AniyomiProvider` (`lib/core/aniyomi/aniyomi_provider.dart`)
/// — deliberately duplicated rather than shared (spec Decision 3). Constructed
/// from a [MihonSourceInfo] returned by [MihonExtensionService.listSources];
/// one instance per native source. Identified by `'mihon:<sourceId>'` (spec
/// Decision 1) so it lives alongside Aniyomi (`ani:`), CloudStream (`cs:`) and
/// JS providers without collisions — never `ani:`, which `sourceTypeOf`
/// hardcodes to anime.
///
/// All data methods forward to the `zangetsu/mihon` channel. The bridge's
/// method surface deliberately diverges from the anime twin in ONE place:
/// chapter listing is `getChapters`, not `getEpisodes` (manga domain
/// language — the payload carries `chapter_number`/`scanlator`). Every method
/// name and argument key below is verified against
/// `android/app/src/main/kotlin/com/spyou/watch_app/mihon/MihonBridge.kt`'s
/// `when` block, not inferred from the anime twin.
///
/// This is a reading source, not a video one: [getVideoSources] always
/// returns `[]` and [getText] always throws — Mihon is manga-only, novels
/// stay on the JS path.
///
/// Unlike the anime twin, the channel-calling methods below do NOT guard on
/// `Platform.isAndroid`. That guard is provably redundant: [_safeInvoke]'s
/// catch-all already turns a missing channel (`MissingPluginException`, e.g.
/// on iOS, where Mihon is Android-only) into the same null/empty result the
/// guard short-circuits to — so dropping it changes no production behaviour.
/// What it does change is testability: `Platform.isAndroid` reflects the
/// real host OS and can't be faked in `flutter test` (verified — it reports
/// `false` on the macOS/Linux test runner), so a guarded method is simply
/// unreachable from a host unit test. That's exactly why no test file for
/// `AniyomiProvider`/`CloudStreamProvider` exercises their channel calls
/// either. This task requires real, assertable channel-argument tests, so
/// the guard is dropped here rather than carried over unreachable.
class MihonProvider implements BaseProvider, ReadingProvider {
  MihonProvider({required this.info});

  /// The native source descriptor this provider wraps.
  final MihonSourceInfo info;

  @override
  String get sourceId => 'mihon:${info.id}';

  @override
  String get displayName => info.name;

  /// Package name of the owning extension APK.
  String get pkg => info.pkg;

  /// Extension versionName (display).
  String get version => info.version;

  /// Extension versionCode (used for update comparisons).
  int get versionCode => info.versionCode;

  /// Headers for cover/thumbnail image requests. Many manga image hosts
  /// return 403 without a `Referer`, and a source's default headers often
  /// omit it — so fall back to the source base URL. Same workaround as the
  /// anime twin's `_coverHeaders`.
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
    type: ProviderType.manga,
  );

  /// Returns two [HomeSection]s — "Popular" and "Latest" — sourced from
  /// the corresponding native calls. Category is unused for Mihon.
  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
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
          more: BrowseMore(sourceId: sourceId, kind: 'mihon_popular'),
        ),
      if (latestItems.isNotEmpty)
        HomeSection(
          title: 'Latest',
          items: latestItems,
          more: BrowseMore(sourceId: sourceId, kind: 'mihon_latest'),
        ),
    ];
    // Return the (possibly empty) list rather than null. `null` is
    // SourceRepository.home()'s signal for "this provider has no home page",
    // which makes it fall back to calling popular() three times at dateRange
    // 1/30/0 — and [popular] here ignores dateRange entirely, so those are
    // three byte-identical requests to a source that just failed twice.
    // Measured: a failed load cost 5 requests instead of 2.
    //
    // Empty vs null is invisible to the user: home() filters empty sections
    // out either way, so the screen shows the same "source isn't responding"
    // state — it just gets there without hammering the source.
    return sections;
  }

  /// Returns the source's popular manga page.
  /// [category] is not used — Mihon sources do not distinguish sub/dub.
  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    return _invokeMangaList('getPopular', {'sourceId': info.id, 'page': page});
  }

  /// Returns the source's latest-updated manga page. Public wrapper over
  /// [_fetchLatest] so the "See all" browse grid can page it (mirrors the
  /// already-public [popular]).
  Future<List<MediaItem>> latest({int page = 1}) => _fetchLatest(page: page);

  /// Returns the source's latest-updated manga page.
  Future<List<MediaItem>> _fetchLatest({int page = 1}) =>
      _invokeMangaList('getLatest', {'sourceId': info.id, 'page': page});

  /// Searches the source for [query]. [category] is unused by Mihon sources.
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
    final args = <String, dynamic>{
      'sourceId': info.id,
      'query': query,
      'page': page,
    };
    if (filtersJson != null && filtersJson.isNotEmpty) {
      args['filters'] = filtersJson;
    }
    return _invokeMangaList('search', args);
  }

  /// Returns the typed filter schema for this source, or an empty list when
  /// the source has no filters (or the channel is unavailable).
  Future<List<MihonFilter>> getFilters() async {
    final raw = await _safeInvoke('getFilterList', {'sourceId': info.id});
    if (raw == null || raw.isEmpty) return const [];
    return MihonFilters.parse(raw);
  }

  /// Fetches the detail page and chapter list for [url] in parallel and
  /// returns a [MediaDetail] with the chapters embedded.
  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    final fallback = MediaDetail(
      id: url,
      title: '',
      url: url,
      type: ProviderType.manga,
      sourceId: sourceId,
    );

    // Mihon separates getDetails (manga metadata) from getChapters (list).
    // Fetch both in parallel to keep latency tight.
    final res = await Future.wait<String?>([
      _safeInvoke('getDetails', {'sourceId': info.id, 'url': url}),
      _safeInvoke('getChapters', {'sourceId': info.id, 'url': url}),
    ]);
    final chapters = _parseChapterList(res[1]);
    final detailRaw = res[0];

    if (detailRaw == null || detailRaw.isEmpty) {
      return fallback.copyWith(episodes: chapters);
    }
    try {
      final j = jsonDecode(detailRaw) as Map<String, dynamic>;
      return mediaDetailFromSManga(
        j,
        chapters,
        sourceId: sourceId,
        headers: _coverHeaders,
      );
    } catch (e) {
      debugPrint('[mihon] getDetail parse failed for $url: $e');
      return fallback.copyWith(episodes: chapters);
    }
  }

  /// Returns the chapter list for [url] as [Episode]s (the app's shared
  /// chapter/episode model). [category] is unused.
  ///
  /// Invokes the native `getChapters` method — NOT `getEpisodes`, which is
  /// the anime bridge's name for the same concept. This is the one
  /// deliberate, documented divergence between the two bridges (see
  /// `MihonBridge.kt`'s method-surface doc comment).
  @override
  Future<List<Episode>> getEpisodes(
    String url, {
    String category = 'sub',
  }) async {
    final raw = await _safeInvoke('getChapters', {
      'sourceId': info.id,
      'url': url,
    });
    return _parseChapterList(raw);
  }

  /// Mihon is a reading source, not a video one — there are no playable
  /// streams to return. Real video playback stays on the anime/CS/JS paths.
  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) async => const [];

  // ── ReadingProvider ─────────────────────────────────────────────────────────

  /// Returns the ordered page images for [chapterUrl].
  ///
  /// The native bridge resolves every page's `imageUrl` (including two-step
  /// sources that need a second request per page) before replying, so an
  /// element with a null `imageUrl` here means resolution genuinely failed
  /// for that one page. [pagesFromJson] drops such pages rather than failing
  /// the whole chapter — one bad page must not take the rest down with it.
  @override
  Future<List<PageImage>> getPages(String chapterUrl) async {
    final raw = await _safeInvoke('getPages', {
      'sourceId': info.id,
      'url': chapterUrl,
    });
    if (raw == null || raw.isEmpty) return const [];
    try {
      final pages = pagesFromJson(jsonDecode(raw));
      if (pages.isEmpty) return pages;
      // Attach the source's Cloudflare session (cf_clearance cookie + matching
      // UA) to each page so Flutter's image loader can fetch pages from a
      // Cloudflare-gated image host (e.g. static.comix.to). Empty/no-op for
      // sources that aren't behind Cloudflare.
      final cookieHeaders = await _imageCookieHeaders(pages.first.url);
      if (cookieHeaders.isEmpty) return pages;
      return [
        for (final p in pages)
          PageImage(url: p.url, headers: {...?p.headers, ...cookieHeaders}),
      ];
    } catch (e) {
      debugPrint('[mihon] getPages parse failed for $chapterUrl: $e');
      return const [];
    }
  }

  /// Cookie + User-Agent to send with page-image requests so
  /// `cached_network_image` can clear a Cloudflare-gated image host, via the
  /// native `imageCookie` (reads the WebView CookieManager the solve wrote to).
  Future<Map<String, String>> _imageCookieHeaders(String url) async {
    try {
      final res = await _mihonChannel
          .invokeMethod<Map<dynamic, dynamic>>('imageCookie', {'url': url});
      if (res == null) return const {};
      return res.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return const {};
    }
  }

  /// Mihon manga sources never serve novel text — novels stay on the JS
  /// provider path. Always throws.
  @override
  Future<ChapterText> getText(String chapterUrl) {
    throw UnsupportedError(
      'MihonProvider is manga-only; it has no text chapters ($chapterUrl).',
    );
  }

  // ── private helpers ─────────────────────────────────────────────────────────

  /// Invokes [method] on the mihon channel with [args], returning the raw
  /// JSON string result. Returns null on any error so callers degrade cleanly.
  ///
  /// When [surfaceCloudflare] is true, a native `CLOUDFLARE` failure is re-thrown
  /// as a [CloudflareRequiredException] (carrying the URL to solve) instead of
  /// being swallowed — so the browse/home path can offer a "Solve Cloudflare"
  /// action. Detail/chapter/page calls leave it false and keep degrading to
  /// null, since the user solves once from the browse screen and the cached
  /// cf_clearance then unblocks everything.
  Future<String?> _safeInvoke(
    String method,
    Map<String, dynamic> args, {
    bool surfaceCloudflare = false,
  }) async {
    try {
      return await _mihonChannel.invokeMethod<String>(method, args);
    } on PlatformException catch (e) {
      if (surfaceCloudflare && e.code == 'CLOUDFLARE') {
        throw CloudflareRequiredException(
          (e.message?.isNotEmpty ?? false) ? e.message! : info.baseUrl,
        );
      }
      debugPrint('[mihon] $method(sourceId=${info.id}) failed: $e');
      return null;
    } catch (e) {
      debugPrint('[mihon] $method(sourceId=${info.id}) failed: $e');
      return null;
    }
  }

  /// Invokes [method], decodes the JSON array result as SManga objects, and
  /// maps each to a [MediaItem].
  Future<List<MediaItem>> _invokeMangaList(
    String method,
    Map<String, dynamic> args,
  ) async {
    final raw = await _safeInvoke(method, args, surfaceCloudflare: true);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(
            (j) => mediaItemFromSManga(
              j,
              sourceId: sourceId,
              headers: _coverHeaders,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('[mihon] $method parse failed: $e');
      return const [];
    }
  }

  /// Decodes a raw JSON array string of SChapter objects.
  List<Episode> _parseChapterList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final chapters = list
          .whereType<Map<String, dynamic>>()
          .map(episodeFromSChapter)
          .toList();
      return sortChaptersAscending(chapters);
    } catch (_) {
      return const [];
    }
  }
}

/// Mihon/Tachiyomi extensions return chapters newest-first (N→1) — the same
/// SChapter/SManga convention the anime twin's `sortEpisodesAscending` doc
/// comment describes, since Tachiyomi's manga model is where that convention
/// originates. Normalise to chronological order (1→N) so the first chapter
/// reads first and next-chapter navigation works. Sorts by chapter number
/// when every chapter has one (keeps 12 → 12.5 → 13 correct); otherwise
/// reverses the source's newest-first convention.
///
/// Duplicated from `aniyomi_provider.dart`'s `sortEpisodesAscending` rather
/// than imported (spec Decision 3) so the frozen anime file never has to
/// change for a manga change.
@visibleForTesting
List<Episode> sortChaptersAscending(List<Episode> chapters) {
  if (chapters.length < 2) return chapters;
  if (chapters.every((e) => e.number != null)) {
    final sorted = [...chapters]..sort((a, b) => a.number!.compareTo(b.number!));
    return sorted;
  }
  return chapters.reversed.toList();
}
