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

  /// Set by the user through "Wrong show?". A pinned match is never replaced
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

/// Canonical id → [SourceMatch]. One Hive box, backed up with settings.
class MatchStore {
  MatchStore._(this._box);
  final Box<Map> _box;

  static const String boxName = 'zmode_matches';

  static Future<MatchStore> open() async =>
      MatchStore._(await openBoxSafely<Map>(boxName));

  SourceMatch? get(ZCanonical c) => SourceMatch.fromMap(_box.get(c.key));

  /// A guess. Does nothing if the user has pinned this title.
  Future<void> save(ZCanonical c, SourceMatch m) async {
    if (get(c)?.pinned == true) return;
    await _box.put(c.key, m.toMap());
  }

  /// The user's choice. Always wins.
  Future<void> pin(ZCanonical c, SourceMatch m) =>
      _box.put(c.key, SourceMatch(
        sourceId: m.sourceId,
        showUrl: m.showUrl,
        showId: m.showId,
        showTitle: m.showTitle,
        pinned: true,
      ).toMap());

  Future<void> forget(ZCanonical c) => _box.delete(c.key);
}
