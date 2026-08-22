import 'package:dio/dio.dart';

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

/// Accurate opening/ending skip times for ANIME via AniSkip
/// (api.aniskip.com — free, no API key). Resolves the anime's MAL id from
/// AniList by title, then queries AniSkip with the episode number + length.
/// Returns `[]` for anything without data (movies, live-action, unmatched
/// episodes) so the caller falls back to a manual skip.
class SkipService {
  SkipService(this._dio);
  final Dio _dio;

  static const String _anilist = 'https://graphql.anilist.co';
  static const String _query =
      'query(\$search:String){ Media(search:\$search, type:ANIME){ idMal } }';

  // Cache MAL id per title so we don't re-hit AniList every episode.
  final Map<String, int?> _malCache = {};

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
