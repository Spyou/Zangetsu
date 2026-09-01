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

/// Simkl publishes its whole release calendar as two static JSON files on a
/// CDN — no key, no paging, one request each. That matters because TMDB
/// Discover cannot express "a TV calendar" at all: its only forward date
/// filter for series is `first_air_date`, which is the PREMIERE, so an
/// ongoing show's next episode can never appear. See [ComingSoonService].
///
/// Rows without a TMDB id are dropped. Detail is keyed by tmdbId
/// (`zm://movie/tmdb:<n>`), so a row without one would render as a tappable
/// calendar entry that opens nothing.
List<ComingSoonEntry> parseSimklCalendar(List<dynamic> rows,
    {required bool isTv}) {
  final out = <ComingSoonEntry>[];
  // The feed repeats a title across days, and occasionally repeats the same
  // day+episode outright; key on all three so a real weekly airing survives
  // while a duplicate does not.
  final seen = <String>{};
  for (final raw in rows) {
    if (raw is! Map) continue;
    final ids = raw['ids'];
    final tmdbRaw = ids is Map ? ids['tmdb'] : null;
    final tmdbId = tmdbRaw is int ? tmdbRaw : int.tryParse('${tmdbRaw ?? ''}');
    if (tmdbId == null) continue;

    final title = (raw['title'] as String? ?? '').trim();
    if (title.isEmpty) continue;

    // Dates carry an offset ("...T00:00:00-04:00"); local is what the day
    // grouping and the week strip work in.
    final date = DateTime.tryParse('${raw['date'] ?? ''}')?.toLocal();
    if (date == null) continue;

    String? epLabel;
    final ep = raw['episode'];
    if (isTv && ep is Map) {
      final sn = ep['season'], en = ep['episode'];
      if (sn != null && en != null) epLabel = 'S${sn}E$en';
    }

    final key = '$tmdbId|${date.toIso8601String()}|${epLabel ?? ''}';
    if (!seen.add(key)) continue;

    final poster = (raw['poster'] as String?)?.trim();
    out.add(ComingSoonEntry(
      tmdbId: tmdbId,
      isTv: isTv,
      title: title,
      posterUrl: (poster == null || poster.isEmpty)
          ? null
          : 'https://simkl.in/posters/${poster}_m.jpg',
      releaseDate: date,
      episodeLabel: epLabel,
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

/// Fetches genuinely-upcoming movies + TV from TMDB Discover (key added by the
/// Dio interceptor for Tmdb.host). Returns `[]` on any error.
class ComingSoonService {
  ComingSoonService(this._dio);
  final Dio _dio;

  /// Simkl's calendar, or TMDB Discover if that comes back with nothing.
  ///
  /// Cached in memory for [_cacheTtl]: the two files are ~2.8MB together, and
  /// re-opening Schedule should not re-download them. Deliberately NOT on
  /// disk — a stale calendar is worse than a slow one, and the day-level data
  /// it holds turns over constantly.
  Future<List<ComingSoonEntry>> upcoming() async {
    final cached = _cache;
    if (cached != null && DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return cached;
    }
    final simkl = await _fromSimkl();
    if (simkl.isNotEmpty) {
      _cache = simkl;
      _cachedAt = DateTime.now();
      return simkl;
    }
    // Simkl unreachable — TMDB still gives premieres and movie releases, which
    // is far less than a calendar but better than an empty screen.
    return _fromTmdb();
  }

  static const Duration _cacheTtl = Duration(hours: 6);
  List<ComingSoonEntry>? _cache;
  DateTime? _cachedAt;

  static const String _simklTv = 'https://data.simkl.in/calendar/tv.json';
  static const String _simklMovies =
      'https://data.simkl.in/calendar/movie_release.json';

  Future<List<ComingSoonEntry>> _fromSimkl() async {
    try {
      final res = await Future.wait([
        _dio.get<dynamic>(_simklTv),
        _dio.get<dynamic>(_simklMovies),
      ]);
      final tv = res[0].data, movies = res[1].data;
      final merged = mergeSortByDate(
        parseSimklCalendar(tv is List ? tv : const [], isTv: true),
        parseSimklCalendar(movies is List ? movies : const [], isTv: false),
      );
      return onlyUpcoming(merged, DateTime.now());
    } catch (_) {
      return const [];
    }
  }

  Future<List<ComingSoonEntry>> _fromTmdb() async {
    final today = DateTime.now();
    final from = _tmdbDate(today);
    // ~6 weeks out: covers the week strip and the month grid while staying a
    // bounded, fast window. We use Discover with an explicit forward date range
    // instead of /movie/upcoming + /tv/on_the_air — those are rolling lists that
    // are mostly already-released titles (their dates land in the recent past),
    // so onlyUpcoming dropped nearly all of them and the movies side came back
    // empty. Discover returns titles that actually release in the window;
    // popularity.desc leads with the notable ones, not obscure same-day filler.
    final to = _tmdbDate(today.add(const Duration(days: 42)));
    try {
      final movieRes = await _dio.get<dynamic>(
        '${Tmdb.base}/discover/movie',
        queryParameters: {
          'primary_release_date.gte': from,
          'primary_release_date.lte': to,
          'sort_by': 'popularity.desc',
          'with_release_type': '2|3', // theatrical + digital; skips festival/TV-movie noise
        },
      );
      final tvRes = await _dio.get<dynamic>(
        '${Tmdb.base}/discover/tv',
        queryParameters: {
          'first_air_date.gte': from,
          'first_air_date.lte': to,
          'sort_by': 'popularity.desc',
        },
      );
      final merged = mergeSortByDate(
        parseTmdbResults(_results(movieRes.data), isTv: false),
        parseTmdbResults(_results(tvRes.data), isTv: true),
      );
      return onlyUpcoming(merged, today); // safety net; Discover is already future-only
    } catch (_) {
      return const [];
    }
  }

  /// TMDB date filters want `YYYY-MM-DD`.
  static String _tmdbDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  List<dynamic> _results(dynamic data) =>
      (data is Map && data['results'] is List) ? data['results'] as List : const [];
}
