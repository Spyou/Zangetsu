/// The small facts shown in a row at the top of a title's Overview: the age
/// tag ("TV-MA") and the IMDb score. Both are optional; a title that has
/// neither simply shows no extras.
class TitleBadges {
  const TitleBadges({this.ageRating, this.imdbRating});

  final String? ageRating;

  /// One decimal, like "8.5".
  final String? imdbRating;

  bool get isEmpty => ageRating == null && imdbRating == null;

  @override
  bool operator ==(Object other) =>
      other is TitleBadges &&
      other.ageRating == ageRating &&
      other.imdbRating == imdbRating;

  @override
  int get hashCode => Object.hash(ageRating, imdbRating);
}

/// The age certification out of a TMDB title fetched with
/// `append_to_response=release_dates` (movies) or `content_ratings` (series).
///
/// Prefers the US one — the labels people recognise ("PG-13", "TV-MA") — and
/// otherwise takes the first country that has one.
String? certificationFrom(Map<String, dynamic> tmdb, {required bool isTv}) {
  final block = tmdb[isTv ? 'content_ratings' : 'release_dates'];
  final results = block is Map ? block['results'] : null;
  if (results is! List) return null;

  String? certOf(Map<dynamic, dynamic> entry) {
    if (isTv) return _clean(entry['rating']);
    final dates = entry['release_dates'];
    if (dates is! List) return null;
    for (final d in dates) {
      if (d is Map) {
        final c = _clean(d['certification']);
        if (c != null) return c;
      }
    }
    return null;
  }

  String? fallback;
  for (final r in results) {
    if (r is! Map) continue;
    final cert = certOf(r);
    if (cert == null) continue;
    if (r['iso_3166_1'] == 'US') return cert;
    fallback ??= cert;
  }
  return fallback;
}

/// The IMDb id (`tt1234567`) out of a TMDB title fetched with
/// `append_to_response=external_ids`.
String? imdbIdFrom(Map<String, dynamic> tmdb) {
  final ids = tmdb['external_ids'];
  final id = ids is Map ? _clean(ids['imdb_id']) : null;
  return id != null && id.startsWith('tt') ? id : null;
}

/// The TMDB id (and whether it is a series) out of TMDB's "find by IMDb id"
/// answer. Takes the movie match first, then the series one.
({int id, bool isTv})? tmdbFromFind(Map<String, dynamic>? found) {
  int? firstId(Object? list) {
    if (list is! List || list.isEmpty) return null;
    final first = list.first;
    return first is Map ? (first['id'] as num?)?.toInt() : null;
  }

  final movie = firstId(found?['movie_results']);
  if (movie != null) return (id: movie, isTv: false);
  final tv = firstId(found?['tv_results']);
  if (tv != null) return (id: tv, isTv: true);
  return null;
}

/// The IMDb score out of a Cinemeta title answer (`{"meta":{"imdbRating":"8.5"}}`),
/// as one decimal, or null when there is none or it is not above zero.
String? imdbRatingFrom(Map<String, dynamic>? cinemeta) {
  final meta = cinemeta?['meta'];
  final raw = meta is Map ? meta['imdbRating'] : null;
  final value = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
  if (value == null || value <= 0) return null;
  return value.toStringAsFixed(1);
}

/// "1h 45m", "2h", "48m" — or null when the length is unknown.
String? formatRuntime(int? minutes) {
  if (minutes == null || minutes <= 0) return null;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

String? _clean(Object? v) {
  final s = v is String ? v.trim() : null;
  return (s == null || s.isEmpty) ? null : s;
}
