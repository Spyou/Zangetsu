import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// How many times each source has actually played something on this device.
///
/// Deliberately NOT part of [SourceHealthStore]: that answers "is this source
/// working right now" and is built to expire and be cleared, while this is a
/// lifetime tally that must not reset when a source has one bad afternoon.
/// Auto Resolve ranks on the two together — a source that has played 47 times
/// but is timing out today should sink for today and come back after.
///
/// Derived data, not a setting: it rebuilds itself from use, so it is not
/// worth carrying in a backup.
class SourceScoreStore {
  SourceScoreStore._(this._box);

  final Box<int> _box;

  static const String boxName = 'zmode_source_score';

  static Future<SourceScoreStore> open() async =>
      SourceScoreStore._(await openBoxSafely<int>(boxName));

  /// Successful plays recorded for [id]. Zero for a source nobody has used —
  /// never null, because the ranker treats "never played" as a real value
  /// rather than a missing one.
  int plays(String id) => _box.get(id) ?? 0;

  /// One more successful play for [id].
  Future<void> bump(String id) => _box.put(id, plays(id) + 1);

  Future<void> clear() => _box.clear();
}
