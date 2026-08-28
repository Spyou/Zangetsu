import 'package:dio/dio.dart';

import '../models/media_item.dart' show normalizeTitle;
import 'schedule_models.dart';

const String _kAniListEndpoint = 'https://graphql.anilist.co';

/// UTC-epoch-seconds window: local midnight today .. +7 days.
({int startSec, int endSec}) weekWindowUtc(DateTime nowLocal) {
  final startLocal = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
  final endLocal = startLocal.add(const Duration(days: 7));
  return (
    startSec: startLocal.toUtc().millisecondsSinceEpoch ~/ 1000,
    endSec: endLocal.toUtc().millisecondsSinceEpoch ~/ 1000,
  );
}

/// UTC-epoch-seconds window covering the whole calendar month that [anchorLocal]
/// falls in (its 1st .. the 1st of the next month, exclusive).
({int startSec, int endSec}) monthWindowUtc(DateTime anchorLocal) {
  final start = DateTime(anchorLocal.year, anchorLocal.month, 1);
  final end = DateTime(anchorLocal.year, anchorLocal.month + 1, 1);
  return (
    startSec: start.toUtc().millisecondsSinceEpoch ~/ 1000,
    endSec: end.toUtc().millisecondsSinceEpoch ~/ 1000,
  );
}

/// Maps `data['Page']['airingSchedules']` → entries (SFW, valid media only).
List<AiringEntry> parseAiringSchedules(Map<String, dynamic> data) {
  final page = data['Page'];
  final list = (page is Map) ? page['airingSchedules'] : null;
  if (list is! List) return const [];
  final out = <AiringEntry>[];
  for (final raw in list) {
    if (raw is! Map) continue;
    final media = raw['media'];
    if (media is! Map) continue;
    if (media['isAdult'] == true) continue;
    final titleMap = media['title'];
    final english = (titleMap is Map) ? titleMap['english'] as String? : null;
    final romaji = (titleMap is Map) ? titleMap['romaji'] as String? : null;
    final title = (english != null && english.isNotEmpty)
        ? english
        : (romaji ?? '');
    if (title.isEmpty) continue;
    final airingAt = raw['airingAt'];
    if (airingAt is! int) continue;
    final cover = (media['coverImage'] is Map)
        ? media['coverImage']['large'] as String?
        : null;
    final alt = (english != null && english.isNotEmpty && romaji != null &&
            romaji.isNotEmpty && romaji != english)
        ? romaji
        : null;
    out.add(AiringEntry(
      altTitle: alt,
      malId: media['idMal'] as int?,
      title: title,
      coverUrl: cover,
      episode: (raw['episode'] as int?) ?? 0,
      airsAtLocal:
          DateTime.fromMillisecondsSinceEpoch(airingAt * 1000).toLocal(),
      format: (media['format'] as String?) ?? '',
      bannerUrl: media['bannerImage'] as String?,
      synopsis: _cleanDescription(media['description'] as String?),
    ));
  }
  return out;
}

/// AniList descriptions carry lightweight HTML (`<br>`, `<i>`, `<b>`). Strip
/// tags + collapse whitespace so it fits a two-line card synopsis. Null/empty → null.
String? _cleanDescription(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final text = raw
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.isEmpty ? null : text;
}

/// Groups entries by their local calendar day, each day's list time-sorted.
Map<DateTime, List<AiringEntry>> groupByLocalDay(List<AiringEntry> entries) {
  final map = <DateTime, List<AiringEntry>>{};
  for (final e in entries) {
    final day =
        DateTime(e.airsAtLocal.year, e.airsAtLocal.month, e.airsAtLocal.day);
    (map[day] ??= []).add(e);
  }
  for (final list in map.values) {
    list.sort((a, b) => a.airsAtLocal.compareTo(b.airsAtLocal));
  }
  return map;
}

List<AiringEntry> filterByMalIds(List<AiringEntry> entries, Set<int> malIds) =>
    entries.where((e) => e.malId != null && malIds.contains(e.malId)).toList();

/// The shows the "My List" filter should keep.
///
/// MAL ids alone were not enough. A list entry only carries a malId once
/// metadata enrichment has run, and an item added straight from a source
/// usually has none — so the set came out empty, nothing matched, and the
/// schedule claimed you follow nothing while the very same show sat in the
/// unfiltered list. (Verified against BLACK TORCH: AniList publishes
/// `idMal: 61169` for it, so the airing side was fine; the list side had no
/// id to match with.)
///
/// Titles are the fallback, normalized so case and punctuation can't break it.
class FollowedShows {
  const FollowedShows({this.malIds = const {}, this.titles = const {}});

  final Set<int> malIds;

  /// Already normalized via [normalizeTitle].
  final Set<String> titles;

  bool get isEmpty => malIds.isEmpty && titles.isEmpty;

  bool matches(AiringEntry e) {
    if (e.malId != null && malIds.contains(e.malId)) return true;
    if (titles.isEmpty) return false;
    if (titles.contains(normalizeTitle(e.title))) return true;
    final alt = e.altTitle;
    return alt != null && titles.contains(normalizeTitle(alt));
  }
}

List<AiringEntry> filterByFollowed(
  List<AiringEntry> entries,
  FollowedShows followed,
) =>
    entries.where(followed.matches).toList();

/// Fetches this week's anime airing schedule from AniList (public, no auth).
class AiringService {
  AiringService(this._dio);
  final Dio _dio;

  static const String _query = r'''
query ($start: Int, $end: Int, $page: Int) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    airingSchedules(airingAt_greater: $start, airingAt_lesser: $end, sort: TIME) {
      episode
      airingAt
      media {
        idMal
        title { romaji english }
        coverImage { large }
        bannerImage
        description(asHtml: false)
        format
        isAdult
      }
    }
  }
}''';

  /// Returns every SFW airing event in the next 7 days, or `[]` on any error.
  Future<List<AiringEntry>> weekAiring({DateTime? now}) {
    final win = weekWindowUtc(now ?? DateTime.now());
    return _fetchRange(win.startSec, win.endSec, maxPages: 10);
  }

  /// Every SFW airing event in the calendar month [anchor] falls in, or `[]`
  /// on error. AniList only has confirmed slots ~2 weeks out, so later days are
  /// sparse; cap pages so the fetch stays quick (skeleton covers the wait).
  Future<List<AiringEntry>> monthAiring(DateTime anchor) {
    final win = monthWindowUtc(anchor);
    return _fetchRange(win.startSec, win.endSec, maxPages: 12);
  }

  /// Paginated AniList airingSchedules fetch for a UTC-epoch-seconds window.
  /// Fetches page 1 first (so an empty or single-page window bails cheaply),
  /// then the remaining pages in one parallel batch. AniList reports
  /// hasNextPage against a capped total, so the old page-by-page loop never
  /// broke early and always ran the full [maxPages] one after another — the
  /// parallel batch collapses that to ~2 round-trips instead of [maxPages].
  /// Never throws — returns `[]` on any error.
  Future<List<AiringEntry>> _fetchRange(
    int startSec,
    int endSec, {
    required int maxPages,
  }) async {
    try {
      final first = await _fetchPage(startSec, endSec, 1);
      if (maxPages <= 1 || !first.hasNext) return first.entries;
      final rest = await Future.wait([
        for (var page = 2; page <= maxPages; page++)
          _fetchPage(startSec, endSec, page),
      ]);
      return [
        ...first.entries,
        for (final r in rest) ...r.entries,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// One AniList page → its entries plus whether AniList claims more pages.
  Future<({List<AiringEntry> entries, bool hasNext})> _fetchPage(
    int startSec,
    int endSec,
    int page,
  ) async {
    final res = await _dio.post<dynamic>(
      _kAniListEndpoint,
      data: {
        'query': _query,
        'variables': {'start': startSec, 'end': endSec, 'page': page},
      },
      options: Options(
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final data = res.data;
    final root = (data is Map && data['data'] is Map)
        ? Map<String, dynamic>.from(data['data'] as Map)
        : const <String, dynamic>{};
    final page0 = root['Page'];
    final hasNext = (page0 is Map && page0['pageInfo'] is Map)
        ? page0['pageInfo']['hasNextPage'] == true
        : false;
    return (entries: parseAiringSchedules(root), hasNext: hasNext);
  }
}
