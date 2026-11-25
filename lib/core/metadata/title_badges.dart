/// The small facts shown in a row at the top of a title's Overview: the age
/// tag ("TV-MA") and the IMDb score. Both are optional; a title that has
/// neither simply shows no extras.
class TitleBadges {
  const TitleBadges({
    this.ageRating,
    this.imdbRating,
    this.directors = const [],
    this.writers = const [],
    this.creators = const [],
  });

  final String? ageRating;

  /// One decimal, like "8.5".
  final String? imdbRating;

  /// The people behind the title, when they can be found. [creators] is for a
  /// series' "created by".
  final List<String> directors;
  final List<String> writers;
  final List<String> creators;

  bool get isEmpty =>
      ageRating == null &&
      imdbRating == null &&
      directors.isEmpty &&
      writers.isEmpty &&
      creators.isEmpty;

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is TitleBadges &&
      other.ageRating == ageRating &&
      other.imdbRating == imdbRating &&
      _same(other.directors, directors) &&
      _same(other.writers, writers) &&
      _same(other.creators, creators);

  @override
  int get hashCode => Object.hash(
    ageRating,
    imdbRating,
    Object.hashAll(directors),
    Object.hashAll(writers),
    Object.hashAll(creators),
  );
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

/// Up to [max] distinct names out of a list of names, or of `{name: ...}` maps.
List<String> namesFrom(Object? list, {int max = 5}) {
  if (list is! List) return const [];
  final out = <String>[];
  for (final item in list) {
    final name = item is Map ? _clean(item['name']) : _clean(item);
    if (name != null && !out.contains(name)) out.add(name);
    if (out.length >= max) break;
  }
  return out;
}

/// Director and writer names out of a Cinemeta title answer
/// (`{"meta":{"director":["A"],"writer":["B","C"]}}`).
({List<String> directors, List<String> writers}) cinemetaCredits(
  Map<String, dynamic>? cinemeta,
) {
  final meta = cinemeta?['meta'];
  if (meta is! Map) return (directors: const [], writers: const []);
  return (
    directors: namesFrom(meta['director']),
    writers: namesFrom(meta['writer']),
  );
}

/// Director and writer names out of a TMDB movie fetched with
/// `append_to_response=credits`.
({List<String> directors, List<String> writers}) tmdbCrewCredits(
  Map<String, dynamic> tmdb,
) {
  final credits = tmdb['credits'];
  final crew = credits is Map ? credits['crew'] : null;
  if (crew is! List) return (directors: const [], writers: const []);
  const writerJobs = {'Writer', 'Screenplay', 'Story', 'Novel'};
  final directors = <String>[];
  final writers = <String>[];
  for (final c in crew) {
    if (c is! Map) continue;
    final name = _clean(c['name']);
    final job = _clean(c['job']);
    if (name == null || job == null) continue;
    if (job == 'Director' && !directors.contains(name)) directors.add(name);
    if (writerJobs.contains(job) && !writers.contains(name)) writers.add(name);
  }
  return (
    directors: directors.take(5).toList(),
    writers: writers.take(5).toList(),
  );
}

/// "Created by" names out of a TMDB series.
List<String> tmdbCreators(Map<String, dynamic> tmdb) =>
    namesFrom(tmdb['created_by']);

/// Director and writer names out of an AniList anime's `staff` edges
/// (`{staff:{edges:[{role, node:{name:{full}}}]}}`).
({List<String> directors, List<String> writers}) anilistStaffCredits(
  Map<String, dynamic>? media,
) {
  final staff = media?['staff'];
  final edges = staff is Map ? staff['edges'] : null;
  if (edges is! List) return (directors: const [], writers: const []);
  const directorRoles = {'Director', 'Chief Director'};
  const writerRoles = {
    'Original Creator',
    'Original Story',
    'Series Composition',
    'Script',
  };
  final directors = <String>[];
  final writers = <String>[];
  for (final e in edges) {
    if (e is! Map) continue;
    final role = _clean(e['role']);
    final node = e['node'];
    final name = node is Map && node['name'] is Map
        ? _clean(node['name']['full'])
        : null;
    if (role == null || name == null) continue;
    if (directorRoles.contains(role) && !directors.contains(name)) {
      directors.add(name);
    }
    if (writerRoles.contains(role) && !writers.contains(name)) {
      writers.add(name);
    }
  }
  return (
    directors: directors.take(4).toList(),
    writers: writers.take(4).toList(),
  );
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
