import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/page_content.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import '../provider/base_provider.dart';
import '../provider/reading_provider.dart';
import 'lnreader_extension_service.dart';
import 'lnreader_manager.dart';

/// A single LNReader plugin wrapped as a [BaseProvider] + [ReadingProvider].
///
/// Structural twin of `MihonProvider` (`lib/core/mihon/mihon_provider.dart`)
/// — deliberately duplicated rather than shared, same as that file is a twin
/// of the Aniyomi one. Identified by `'lnr:<pluginId>'` so it lives alongside
/// `mihon:`, `ani:`, `cs:` and JS providers without collisions.
///
/// Built from stored [LnReaderPluginMeta] alone — constructing one must NEVER
/// build the ~450KB QuickJS runtime or load the plugin's JS. That only
/// happens lazily, inside a data method, via [LnReaderManager.ensureLoaded] /
/// [LnReaderManager.callPlugin]. This is what lets `SourceRepository`
/// register a provider for every installed novel source at startup without
/// paying any LNReader runtime cost until one is actually opened.
///
/// This is a reading source, not a video one: [getVideoSources] always
/// returns `[]` and [getPages] always throws — LNReader is novel-only, manga
/// stays on the Mihon path.
class LnReaderProvider implements BaseProvider, ReadingProvider {
  LnReaderProvider({required this.manager, required this.meta});

  final LnReaderManager manager;
  final LnReaderPluginMeta meta;

  @override
  String get sourceId => 'lnr:${meta.id}';

  @override
  String get displayName => meta.name;

  /// Plugin base URL — relative `path`/`cover` values are resolved against
  /// it. Comes straight from the stored index entry, not a runtime read.
  String get site => meta.site;

  // ── BaseProvider ────────────────────────────────────────────────────────────

  /// Built entirely from [meta] — no runtime involved, so calling this alone
  /// never triggers a plugin load.
  @override
  Future<ProviderInfo> getInfo() async => ProviderInfo(
    name: meta.name,
    // ponytail: the plugin index never carries a lang field beyond the
    // top-level one already on meta — fall back to 'en' the same way the
    // pre-refactor runtime-backed getInfo() did when it was absent.
    lang: meta.lang.isEmpty ? 'en' : meta.lang,
    baseUrl: meta.site,
    type: ProviderType.novel,
    version: meta.version.isEmpty ? null : meta.version,
  );

  /// A single "Popular" row, or null when the plugin returned nothing —
  /// there's no separate "latest" concept surfaced here (unlike Mihon's two
  /// rows), so this stays a one-call mirror rather than fetching twice.
  ///
  /// Delegates to [popular], which is what actually triggers the lazy
  /// runtime build — no direct plugin call needed here.
  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
    final items = await popular();
    return items.isEmpty
        ? null
        : [
            HomeSection(
              title: 'Popular',
              items: items,
              // Paginable, so the "See all" grid can infinite-scroll — popular()
              // already takes a page. (Mirrors Mihon/Aniyomi's `more`.)
              more: BrowseMore(sourceId: sourceId, kind: 'lnr_popular'),
            ),
          ];
  }

  /// [category]/[dateRange] are unused — LNReader plugins have no sub/dub or
  /// trending-window concept.
  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    await manager.ensureLoaded(meta.id);
    final filters = manager.filtersFor(meta.id);
    return _fetchNovelList('popularNovels', [
      page,
      {'showLatestNovels': false, 'filters': filters},
    ]);
  }

  /// [category] is unused. `searchNovels(term, page)` takes no filters
  /// argument (unlike `popularNovels`) — verified against the design spec's
  /// plugin-interface mapping.
  @override
  Future<List<MediaItem>> search(String query, int page, {String category = ''}) async {
    await manager.ensureLoaded(meta.id);
    return _fetchNovelList('searchNovels', [query, page]);
  }

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    final fallback = MediaDetail(
      id: url,
      title: '',
      url: url,
      type: ProviderType.novel,
      sourceId: sourceId,
    );
    await manager.ensureLoaded(meta.id);
    final raw = await _safeCall('parseNovel', [url]);
    if (raw is! Map) return fallback;
    final j = Map<String, dynamic>.from(raw);
    return MediaDetail(
      id: url,
      title: (j['name'] as String?) ?? '',
      cover: _resolve(j['cover'] as String?),
      url: url,
      description: j['summary'] as String?,
      status: _statusFromString(j['status'] as String?),
      genres: j['genres'] is List ? List<String>.from(j['genres'] as List) : const [],
      // MediaDetail has no dedicated author field — fold it into studios,
      // the same slot MihonProvider's mapping uses for SManga's author/artist.
      studios: [
        if ((j['author'] as String?)?.isNotEmpty ?? false) j['author'] as String,
      ],
      episodes: _chaptersFromNovel(j),
      type: ProviderType.novel,
      sourceId: sourceId,
    );
  }

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) async {
    await manager.ensureLoaded(meta.id);
    final raw = await _safeCall('parseNovel', [url]);
    if (raw is! Map) return const [];
    return _chaptersFromNovel(Map<String, dynamic>.from(raw));
  }

  /// LNReader is a reading source, not a video one — no playable streams.
  /// Doesn't touch the runtime at all.
  @override
  Future<List<VideoSource>> getVideoSources(String episodeUrl, {bool fast = false}) async =>
      const [];

  // ── ReadingProvider ─────────────────────────────────────────────────────────

  /// LNReader plugins serve novel text, never page images — manga stays on
  /// the Mihon path.
  @override
  Future<List<PageImage>> getPages(String chapterUrl) {
    throw UnsupportedError(
      'LnReaderProvider is novel-only; it has no page images ($chapterUrl).',
    );
  }

  @override
  Future<ChapterText> getText(String chapterUrl) async {
    await manager.ensureLoaded(meta.id);
    final raw = await _safeCall('parseChapter', [chapterUrl]);
    // A failed parse (dead site, 403, Cloudflare, timeout — _safeCall returns
    // null) used to come back as an empty-but-successful chapter: the reader
    // showed a blank page with no error and no Retry, and one flick on that
    // page counted as "read to the end", marking it finished AND scrobbling it
    // to the user's tracker. Throw instead so the reader's existing error path
    // handles it. An empty String from a working plugin is left alone — that's
    // a real (if odd) chapter, not a failure.
    if (raw is! String) {
      throw StateError('Could not load this chapter from ${meta.name}.');
    }
    return ChapterText(html: raw);
  }

  // ── private helpers ─────────────────────────────────────────────────────────

  /// Invokes [method] on the plugin through the manager, catching any
  /// JS/timeout failure so callers degrade cleanly (same role as
  /// MihonProvider's `_safeInvoke`).
  Future<dynamic> _safeCall(String method, List<Object?> args) async {
    try {
      return await manager.callPlugin(meta.id, method, args);
    } catch (e) {
      debugPrint('[lnreader] $method(${meta.id}) failed: $e');
      return null;
    }
  }

  /// Invokes [method] expecting a JSON array of `{name, path, cover?}`
  /// novels and maps it to [MediaItem]s.
  Future<List<MediaItem>> _fetchNovelList(String method, List<Object?> args) async {
    final raw = await _safeCall(method, args);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((j) => _mediaItemFromNovel(Map<String, dynamic>.from(j)))
        .toList();
  }

  MediaItem _mediaItemFromNovel(Map<String, dynamic> j) {
    final path = (j['path'] as String?) ?? '';
    return MediaItem(
      id: path,
      title: (j['name'] as String?) ?? '',
      cover: _resolve(j['cover'] as String?),
      url: path,
      type: ProviderType.novel,
      sourceId: sourceId,
    );
  }

  /// Maps `parseNovel`'s `chapters` array to [Episode]s. `url` stays the raw
  /// chapter `path` (round-tripped verbatim into `parseChapter`) — never
  /// resolved against [site], unlike [cover] which the app renders directly.
  List<Episode> _chaptersFromNovel(Map<String, dynamic> j) {
    final chaptersRaw = j['chapters'];
    if (chaptersRaw is! List) return const [];
    return [
      for (var i = 0; i < chaptersRaw.length; i++)
        if (chaptersRaw[i] is Map)
          _episodeFromChapter(Map<String, dynamic>.from(chaptersRaw[i] as Map), i),
    ];
  }

  Episode _episodeFromChapter(Map<String, dynamic> j, int index) {
    final path = (j['path'] as String?) ?? '';
    final chapterNumber = (j['chapterNumber'] as num?)?.toDouble();
    final releaseTime = j['releaseTime'];
    // Only a couple of novel plugins report one (RLIB, rezerowebnovelfr), but
    // it's the same field the manga path uses, so they get the label for free.
    final scanlator = scanlatorLabel(j['scanlator'] as String?);
    return Episode(
      id: path.isNotEmpty ? path : 'ch-$index',
      title: (j['name'] as String?) ?? '',
      number: chapterNumber ?? (index + 1).toDouble(),
      url: path,
      date: (releaseTime is String && releaseTime.isNotEmpty) ? releaseTime : null,
      scanlator: scanlator,
    );
  }

  /// Resolves a possibly-relative `path`/`cover` value against [site]. Falls
  /// back to the raw value when it's already absolute, [site] is empty, or
  /// parsing fails.
  String? _resolve(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (site.isEmpty) return path;
    try {
      return Uri.parse(site).resolve(path).toString();
    } catch (_) {
      return path;
    }
  }
}

/// LNReader's `NovelStatus` values (`@libs/novelStatus`) mapped onto the
/// app's shared [MediaStatus] enum. Case-insensitive since plugins are not
/// consistent about casing.
MediaStatus _statusFromString(String? s) {
  switch (s?.toLowerCase().trim()) {
    case 'ongoing':
      return MediaStatus.ongoing;
    case 'completed':
    case 'publishing finished':
      return MediaStatus.completed;
    case 'on hiatus':
    case 'hiatus':
      return MediaStatus.hiatus;
    case 'cancelled':
    case 'canceled':
      return MediaStatus.cancelled;
    default:
      return MediaStatus.unknown;
  }
}
