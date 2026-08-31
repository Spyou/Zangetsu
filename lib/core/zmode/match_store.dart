import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import 'zmode_ids.dart';

/// Which source show a metadata title plays through.
class SourceMatch {
  const SourceMatch({
    required this.sourceId,
    required this.showUrl,
    required this.showId,
    required this.showTitle,
    required this.pinned,
  });

  final String sourceId;
  final String showUrl;
  final String showId;
  final String showTitle;

  /// Set by the user through "Wrong title?". A pinned match is never replaced
  /// by a guess.
  final bool pinned;

  Map<String, dynamic> toMap() => {
    'sourceId': sourceId,
    'showUrl': showUrl,
    'showId': showId,
    'showTitle': showTitle,
    'pinned': pinned,
  };

  static SourceMatch? fromMap(dynamic m) {
    if (m is! Map) return null;
    final sourceId = m['sourceId'], showUrl = m['showUrl'];
    if (sourceId is! String || showUrl is! String) return null;
    return SourceMatch(
      sourceId: sourceId,
      showUrl: showUrl,
      showId: m['showId'] is String ? m['showId'] as String : '',
      showTitle: m['showTitle'] is String ? m['showTitle'] as String : '',
      pinned: m['pinned'] == true,
    );
  }
}

/// Per-title, per-source matches, plus which source is currently selected for
/// each title. One Hive box, two key shapes:
///  - a match:            `'${c.key}@$sourceId'`      → [SourceMatch.toMap]
///  - a title's selection: `'sel:${c.key}'`            → `{'sourceId': ...}`
///  - a remembered miss:   `'miss:${c.key}@$sourceId'` → `{'at': millis}`
///
/// The `@`/`sel:` prefixes can never collide with each other or with a plain
/// `c.key` — so an entry written by the old (pre-per-source) scheme, keyed by
/// bare `c.key`, is simply never looked up again under this one. It re-matches
/// on next open instead of migrating; no code reads that orphaned key.
class MatchStore {
  MatchStore._(this._box);
  final Box<Map> _box;

  static const String boxName = 'zmode_matches';
  static const String _selPrefix = 'sel:';
  static const String _missPrefix = 'miss:';

  /// How long "this source doesn't have this title" is trusted. A miss is
  /// recorded so the next open doesn't re-search a source that already said
  /// no — that re-search is per source, per visit, and it is what made
  /// opening an unmatched title slow. It expires because sources DO add
  /// titles, so a miss must never be permanent.
  static const Duration missTtl = Duration(hours: 12);

  static Future<MatchStore> open() async =>
      MatchStore._(await openBoxSafely<Map>(boxName));

  String _key(ZCanonical c, String sourceId) => '${c.key}@$sourceId';

  SourceMatch? get(ZCanonical c, String sourceId) =>
      SourceMatch.fromMap(_box.get(_key(c, sourceId)));

  /// A guess for [m.sourceId]. Does nothing if that source is already pinned
  /// for this title.
  Future<void> save(ZCanonical c, SourceMatch m) async {
    if (get(c, m.sourceId)?.pinned == true) return;
    await _box.put(_key(c, m.sourceId), m.toMap());
  }

  /// The user's choice for [m.sourceId]. Always wins for that source.
  Future<void> pin(ZCanonical c, SourceMatch m) => _box.put(
    _key(c, m.sourceId),
    SourceMatch(
      sourceId: m.sourceId,
      showUrl: m.showUrl,
      showId: m.showId,
      showTitle: m.showTitle,
      pinned: true,
    ).toMap(),
  );

  Future<void> forget(ZCanonical c, String sourceId) =>
      _box.delete(_key(c, sourceId));

  String _missKey(ZCanonical c, String sourceId) =>
      '$_missPrefix${c.key}@$sourceId';

  /// True when [sourceId] searched for this title recently and genuinely
  /// didn't have it — the caller should skip re-searching it. False once
  /// [missTtl] has passed, so the source gets another chance.
  bool missedRecently(ZCanonical c, String sourceId) {
    final at = _box.get(_missKey(c, sourceId))?['at'];
    if (at is! int) return false;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    // A negative age means the clock moved backwards; treat that as expired
    // rather than trusting a miss from the "future" indefinitely.
    return age >= 0 && age < missTtl.inMilliseconds;
  }

  Future<void> rememberMiss(ZCanonical c, String sourceId) => _box.put(
    _missKey(c, sourceId),
    {'at': DateTime.now().millisecondsSinceEpoch},
  );

  Future<void> forgetMiss(ZCanonical c, String sourceId) =>
      _box.delete(_missKey(c, sourceId));

  /// Which source plays this title. Null until something has resolved or the
  /// user has picked one.
  String? selectedSource(ZCanonical c) {
    final v = _box.get('$_selPrefix${c.key}')?['sourceId'];
    return v is String ? v : null;
  }

  Future<void> selectSource(ZCanonical c, String sourceId) =>
      _box.put('$_selPrefix${c.key}', {'sourceId': sourceId});
}
