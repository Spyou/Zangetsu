import 'package:dio/dio.dart';

import '../metadata/tmdb.dart';

/// One line of the "content warnings" card: a category and how strong it is.
class ParentalWarning {
  const ParentalWarning(this.label, this.severity);

  final String label;
  final String severity;

  Map<String, String> toJson() => {'label': label, 'severity': severity};

  @override
  bool operator ==(Object other) =>
      other is ParentalWarning &&
      other.label == label &&
      other.severity == severity;

  @override
  int get hashCode => Object.hash(label, severity);
}

/// IMDb "Parents Guide" levels (Violence · Moderate, Profanity · Mild …) for the
/// short card shown when playback starts.
///
/// The votes come from a free community mirror of IMDb's guide, keyed by IMDb
/// id. Only that id is sent — no account or device info. The card is a nicety,
/// so every failure (offline, 404, the service gone) just means "no card":
/// this never throws and never delays playback.
class ParentalGuideService {
  ParentalGuideService(this._dio);

  final Dio _dio;

  static const _base = 'https://api.tiffara.com';
  static final _imdbPattern = RegExp(r'tt\d+');
  static const _maxCached = 200;

  final _byImdb = <String, List<ParentalWarning>>{};
  final _imdbByTmdb = <(bool, int), String>{};

  /// Warnings for a title, worst first, at most five. Empty when unknown.
  Future<List<ParentalWarning>> warnings({
    String? imdbId,
    int? tmdbId,
    required bool isTv,
  }) async {
    try {
      final id = await _resolveImdb(imdbId, tmdbId, isTv);
      if (id == null) return const [];
      final cached = _byImdb[id];
      if (cached != null) return cached;
      final response = await _dio.get<Map<String, dynamic>>(
        '$_base/titles/$id/parentsGuide',
        options: Options(
          headers: const {'Accept': 'application/json'},
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      final result = parse(response.data);
      if (_byImdb.length >= _maxCached) _byImdb.remove(_byImdb.keys.first);
      // A miss is remembered too, so a title with no data isn't re-asked.
      return _byImdb[id] = result;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _resolveImdb(String? imdbId, int? tmdbId, bool isTv) async {
    final direct = imdbId == null ? null : _imdbPattern.stringMatch(imdbId);
    if (direct != null) return direct;
    if (tmdbId == null || tmdbId <= 0) return null;
    final key = (isTv, tmdbId);
    final known = _imdbByTmdb[key];
    if (known != null) return known;
    final response = await _dio.get<Map<String, dynamic>>(
      '${Tmdb.base}/${isTv ? 'tv' : 'movie'}/$tmdbId/external_ids',
    );
    final value = response.data?['imdb_id'];
    if (value is! String || !_imdbPattern.hasMatch(value)) return null;
    return _imdbByTmdb[key] = value;
  }

  // Display order for equal severities, and the IMDb category each one reads.
  static const _categories = <(String, String)>[
    ('SEXUAL_CONTENT', 'Nudity'),
    ('VIOLENCE', 'Violence'),
    ('PROFANITY', 'Profanity'),
    ('ALCOHOL_DRUGS', 'Alcohol/Drugs'),
    ('FRIGHTENING_INTENSE_SCENES', 'Frightening'),
  ];
  static const _rank = {'severe': 0, 'moderate': 1, 'mild': 2};

  /// Turns the service's JSON into the warning lines. A category only counts
  /// when more people voted for some level above "none" than for "none".
  static List<ParentalWarning> parse(Map<String, dynamic>? json) {
    final list = json?['parentsGuide'];
    if (list is! List) return const [];
    final byCategory = <String, Map>{
      for (final item in list)
        if (item is Map && item['category'] is String)
          (item['category'] as String).toUpperCase(): item,
    };
    final found = <(String, String)>[];
    for (final (key, label) in _categories) {
      final level = _dominant(byCategory[key]);
      if (level != null) found.add((label, level));
    }
    // Stable sort: worst first, ties keep the order above.
    final indexed = found.indexed.toList()
      ..sort((a, b) {
        final byRank = (_rank[a.$2.$2] ?? 3).compareTo(_rank[b.$2.$2] ?? 3);
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });
    return [
      for (final (_, (label, level)) in indexed.take(5))
        ParentalWarning(label, level[0].toUpperCase() + level.substring(1)),
    ];
  }

  static String? _dominant(Map? category) {
    final rows = category?['severityBreakdowns'];
    if (rows is! List) return null;
    String? best;
    var bestVotes = -1;
    var noneVotes = 0;
    for (final row in rows) {
      if (row is! Map) continue;
      final level = '${row['severityLevel']}'.toLowerCase();
      final votes = (row['voteCount'] as num?)?.toInt() ?? 0;
      if (level == 'none') {
        noneVotes = votes;
      } else if (_rank.containsKey(level) && votes > bestVotes) {
        // Unknown levels from the service are ignored, never printed.
        best = level;
        bestVotes = votes;
      }
    }
    if (best == null || bestVotes <= noneVotes) return null;
    return best;
  }
}
