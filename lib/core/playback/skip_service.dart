import 'package:dio/dio.dart';

import '../metadata/tmdb.dart';

/// One opening/ending interval to skip.
class SkipInterval {
  const SkipInterval({
    required this.start,
    required this.end,
    required this.type,
  });
  final Duration start;
  final Duration end;
  final String type; // 'op' (opening) | 'ed' (ending) | 'recap'
}

/// Whether [type] names an ending. AniSkip also returns `mixed-ed`, and
/// `endsWith` keeps that on the ending side without catching `mixed-op`
/// (which `contains('ed')` would, since "mixed" itself contains "ed").
bool isEndingSkip(String type) => type.endsWith('ed');

/// Whether [type] names a recap — the "previously on..." replay some episodes
/// open with. Checked BEFORE [isEndingSkip]: 'recap' doesn't end in 'ed', so
/// without its own branch it falls through to the opening toggle and gets
/// skipped by anyone who turned on auto-skip opening.
bool isRecapSkip(String type) => type == 'recap';

/// Which of the three toggles governs [type].
bool _skipEnabled(String type, bool op, bool ed, bool recap) =>
    isRecapSkip(type)
    ? recap
    : isEndingSkip(type)
    ? ed
    : op;

/// Button text for an interval — a recap reads wrong as "Skip Opening".
String skipLabel(String type) => isRecapSkip(type)
    ? 'Skip Recap'
    : isEndingSkip(type)
    ? 'Skip Ending'
    : 'Skip Opening';

/// The interval to auto-skip at [pos], or null when nothing should fire.
///
/// [fired] holds the interval starts (in ms) already skipped for this episode;
/// each one fires at most once, so seeking back into an opening you actually
/// wanted to watch doesn't bounce you straight out of it again. Callers add the
/// returned interval's start to [fired] and clear the set on episode change.
///
/// The last second is left alone: skipping there saves nothing and risks a seek
/// landing past the interval's own end.
SkipInterval? autoSkipAt(
  List<SkipInterval> intervals,
  Duration pos, {
  required bool op,
  required bool ed,
  required bool recap,
  required Set<int> fired,
}) {
  for (final iv in intervals) {
    if (!_skipEnabled(iv.type, op, ed, recap)) continue;
    if (fired.contains(iv.start.inMilliseconds)) continue;
    if (pos >= iv.start && pos < iv.end - const Duration(seconds: 1)) return iv;
  }
  return null;
}

/// Skip timings from AniSkip for anime and IntroDB for movies and series.
class SkipService {
  SkipService(this._dio);
  final Dio _dio;

  static const String _anilist = 'https://graphql.anilist.co';
  static const String _query =
      'query(\$search:String){ Media(search:\$search, type:ANIME){ idMal } }';

  // Cache MAL id per title so we don't re-hit AniList every episode.
  final Map<String, int?> _malCache = {};
  final Map<(bool, int), String> _imdbCache = {};
  static final _imdbPattern = RegExp(r'^tt[0-9]+$');

  Future<List<SkipInterval>> introDbTimes({
    required String? imdbId,
    required int? tmdbId,
    required bool isTv,
    required int? season,
    required double? episode,
    required Duration duration,
  }) async {
    if (duration <= Duration.zero) return const [];
    if (isTv &&
        (season == null ||
            season < 1 ||
            episode == null ||
            !episode.isFinite ||
            episode < 1 ||
            episode != episode.truncateToDouble())) {
      return const [];
    }
    try {
      var id = imdbId;
      if (id == null || !_imdbPattern.hasMatch(id)) {
        if (tmdbId == null || tmdbId <= 0) return const [];
        final key = (isTv, tmdbId);
        id = _imdbCache[key];
        if (id == null) {
          final kind = isTv ? 'tv' : 'movie';
          final response = await _dio.get<Map<String, dynamic>>(
            '${Tmdb.base}/$kind/$tmdbId/external_ids',
          );
          final value = response.data?['imdb_id'];
          if (value is! String || !_imdbPattern.hasMatch(value)) {
            return const [];
          }
          id = _imdbCache[key] = value;
        }
      }
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.introdb.app/segments',
        queryParameters: {
          'imdb_id': id,
          if (isTv) ...{
            'season': season,
            'episode': episode!.toInt(),
          } else
            'is_movie': true,
        },
      );
      final data = response.data;
      if (data == null) return const [];
      final result = <SkipInterval>[];
      for (final entry in const {
        'intro': 'op',
        'recap': 'recap',
        'outro': 'ed',
      }.entries) {
        if (!isTv && entry.key != 'outro') continue;
        final segment = data[entry.key];
        if (data['no_${entry.key}'] == true || segment is! Map) continue;
        final start = segment['start_ms'];
        final end = segment['end_ms'];
        if (start is! int ||
            end is! int ||
            start < 0 ||
            end <= start ||
            end > duration.inMilliseconds) {
          continue;
        }
        result.add(
          SkipInterval(
            start: Duration(milliseconds: start),
            end: Duration(milliseconds: end),
            type: entry.value,
          ),
        );
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Future<int?> _malId(String title) async {
    if (_malCache.containsKey(title)) return _malCache[title];
    int? mal;
    try {
      final res = await _dio.post<dynamic>(
        _anilist,
        data: {
          'query': _query,
          'variables': {'search': title},
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      if (data is Map) {
        final media = (data['data'] as Map?)?['Media'];
        if (media is Map) mal = (media['idMal'] as num?)?.toInt();
      }
    } catch (_) {}
    _malCache[title] = mal;
    return mal;
  }

  /// OP/ED/recap intervals for [episode] of the anime named [title]. [duration] is the
  /// episode length (improves accuracy; 0 is tolerated). Empty when not anime
  /// or not in the AniSkip DB.
  Future<List<SkipInterval>> skipTimes({
    required String title,
    required int episode,
    required Duration duration,
  }) async {
    final mal = await _malId(title);
    if (mal == null) return const [];
    try {
      final res = await _dio.getUri<dynamic>(
        Uri.parse(
          'https://api.aniskip.com/v2/skip-times/$mal/$episode'
          '?types=op&types=ed&types=recap&episodeLength=${duration.inSeconds}',
        ),
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final map = res.data is Map ? res.data as Map : null;
      if (map == null || map['found'] != true) return const [];
      final results = map['results'];
      if (results is! List) return const [];
      final out = <SkipInterval>[];
      for (final r in results) {
        if (r is! Map) continue;
        final iv = r['interval'];
        if (iv is! Map) continue;
        final start = (iv['startTime'] as num?)?.toDouble();
        final end = (iv['endTime'] as num?)?.toDouble();
        if (start == null || end == null || end <= start) continue;
        out.add(
          SkipInterval(
            start: Duration(milliseconds: (start * 1000).round()),
            end: Duration(milliseconds: (end * 1000).round()),
            type: r['skipType']?.toString() ?? 'op',
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
