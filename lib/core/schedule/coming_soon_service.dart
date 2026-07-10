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
    out.add(ComingSoonEntry(
      tmdbId: id,
      isTv: isTv,
      title: title,
      posterUrl: poster,
      releaseDate: date,
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
      return mergeSortByDate(
        parseTmdbResults(movies, isTv: false),
        parseTmdbResults(tv, isTv: true),
      );
    } catch (_) {
      return const [];
    }
  }

  List<dynamic> _results(dynamic data) =>
      (data is Map && data['results'] is List) ? data['results'] as List : const [];
}
