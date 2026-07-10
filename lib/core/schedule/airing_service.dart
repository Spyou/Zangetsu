import 'package:dio/dio.dart';

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
    out.add(AiringEntry(
      malId: media['idMal'] as int?,
      title: title,
      coverUrl: cover,
      episode: (raw['episode'] as int?) ?? 0,
      airsAtLocal:
          DateTime.fromMillisecondsSinceEpoch(airingAt * 1000).toLocal(),
      format: (media['format'] as String?) ?? '',
    ));
  }
  return out;
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
        format
        isAdult
      }
    }
  }
}''';

  /// Returns every SFW airing event in the next 7 days, or `[]` on any error.
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async {
    final win = weekWindowUtc(now ?? DateTime.now());
    final all = <AiringEntry>[];
    try {
      for (var page = 1; page <= 10; page++) {
        final res = await _dio.post<dynamic>(
          _kAniListEndpoint,
          data: {
            'query': _query,
            'variables': {
              'start': win.startSec,
              'end': win.endSec,
              'page': page,
            },
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
        all.addAll(parseAiringSchedules(root));
        final page0 = root['Page'];
        final hasNext =
            (page0 is Map && page0['pageInfo'] is Map)
                ? page0['pageInfo']['hasNextPage'] == true
                : false;
        if (!hasNext) break;
      }
    } catch (_) {
      return const [];
    }
    return all;
  }
}
