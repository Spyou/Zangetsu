import 'package:dio/dio.dart';

import '../metadata/tmdb.dart';
import 'schedule_models.dart';

/// Maps a TMDB results array to entries; drops title-less or poster-and-date-less rows.
List<ComingSoonEntry> parseTmdbResults(List<dynamic> results,
    {required bool isTv}) {
  final out = <ComingSoonEntry>[];
  for (final raw in results) {
    if (raw is! Map) continue;
    final id = raw['id'];
    if (id is! int) continue;
    final title = (isTv ? raw['name'] : raw['title']) as String? ?? '';
    if (title.isEmpty) continue;
    final posterPath = raw['poster_path'] as String?;
    final dateStr = (isTv ? raw['first_air_date'] : raw['release_date']) as String?;
    final date = (dateStr != null && dateStr.isNotEmpty)
        ? DateTime.tryParse(dateStr)
        : null;
    final poster = (posterPath != null && posterPath.isNotEmpty)
        ? '${Tmdb.img}/w342$posterPath'
        : null;
    if (poster == null && date == null) continue;
    final backdropPath = raw['backdrop_path'] as String?;
    final backdrop = (backdropPath != null && backdropPath.isNotEmpty)
        ? '${Tmdb.img}/w780$backdropPath'
        : null;
    final overview = raw['overview'] as String?;
    out.add(ComingSoonEntry(
      tmdbId: id,
      isTv: isTv,
      title: title,
      posterUrl: poster,
      releaseDate: date,
      backdropUrl: backdrop,
      synopsis: (overview != null && overview.trim().isNotEmpty)
          ? overview.trim()
          : null,
    ));
  }
  return out;
}

/// Concatenate + sort ascending by releaseDate; null dates sort last.
List<ComingSoonEntry> mergeSortByDate(
    List<ComingSoonEntry> a, List<ComingSoonEntry> b) {
  final all = [...a, ...b];
  all.sort((x, y) {
    if (x.releaseDate == null && y.releaseDate == null) return 0;
    if (x.releaseDate == null) return 1;
    if (y.releaseDate == null) return -1;
    return x.releaseDate!.compareTo(y.releaseDate!);
  });
  return all;
}

/// Keep only genuinely-upcoming titles (release today or later) plus
/// to-be-announced (null date). TMDB's `/tv/on_the_air` reports shows that
/// are *currently* airing new episodes, but their date is the series premiere
/// — decades old for long-runners like The Daily Show. Without this filter
/// those float to the top of a "Coming Soon" list sorted ascending.
List<ComingSoonEntry> onlyUpcoming(List<ComingSoonEntry> all, DateTime now) {
  final cutoff = DateTime(now.year, now.month, now.day);
  return all
      .where((e) => e.releaseDate == null || !e.releaseDate!.isBefore(cutoff))
      .toList();
}

/// Groups coming-soon entries by their local release day (dated only — TBA
/// entries with a null date are dropped since they can't sit on the calendar).
/// Each day's list is sorted by title. Used by the Schedule month/week grid.
Map<DateTime, List<ComingSoonEntry>> groupSoonByLocalDay(
    List<ComingSoonEntry> entries) {
  final map = <DateTime, List<ComingSoonEntry>>{};
  for (final e in entries) {
    final d = e.releaseDate;
    if (d == null) continue;
    final day = DateTime(d.year, d.month, d.day);
    (map[day] ??= []).add(e);
  }
  for (final list in map.values) {
    list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }
  return map;
}

/// Fetches upcoming movies + on-the-air TV from TMDB (key added by the Dio
/// interceptor for Tmdb.host). Returns `[]` on any error.
class ComingSoonService {
  ComingSoonService(this._dio);
  final Dio _dio;

  Future<List<ComingSoonEntry>> upcoming() async {
    try {
      final movieRes = await _dio.get<dynamic>('${Tmdb.base}/movie/upcoming');
      final tvRes = await _dio.get<dynamic>('${Tmdb.base}/tv/on_the_air');
      final movies = _results(movieRes.data);
      final tv = _results(tvRes.data);
      final merged = mergeSortByDate(
        parseTmdbResults(movies, isTv: false),
        parseTmdbResults(tv, isTv: true),
      );
      return onlyUpcoming(merged, DateTime.now());
    } catch (_) {
      return const [];
    }
  }

  List<dynamic> _results(dynamic data) =>
      (data is Map && data['results'] is List) ? data['results'] as List : const [];
}
