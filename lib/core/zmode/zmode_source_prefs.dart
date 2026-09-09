import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import 'zmode_ids.dart';

/// An explicit, GLOBAL per-kind override of which source plays Z Mode titles.
///
/// This is deliberately rare: the true default is Auto Resolve (every
/// installed source is swept, per title, in the user's priority order — see
/// `SourceOrderPrefs` and `SourceMatcher`). This override only exists for the
/// "source went quiet" recovery picker (`SourceMatcher.chooseSource`), and a
/// per-title pin (`MatchStore.pin`) always wins over it.
///
/// The reason this exists as a stored preference rather than something
/// derived: a remembered id is a synchronous read, so a Detail screen knows
/// its source on the first frame, with no sweep to wait for.
class ZSourcePrefs {
  ZSourcePrefs._(this._box);
  final Box<String> _box;

  static const String boxName = 'zmode_source';

  static Future<ZSourcePrefs> open() async =>
      ZSourcePrefs._(await openBoxSafely<String>(boxName));

  /// Buckets mirror `candidatesForKind`: anime and movie/TV are served by one
  /// streaming pool, so they share one remembered source. Manga and novel have
  /// their own pools and their own.
  static String bucketOf(ZKind kind) => switch (kind) {
    ZKind.manga => 'manga',
    ZKind.novel => 'novel',
    _ => 'video',
  };

  /// The explicit kind default, or null when none has ever been set — in
  /// which case Auto Resolve is what actually plays every title of this kind.
  String? get(ZKind kind) {
    final v = _box.get(bucketOf(kind))?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> set(ZKind kind, String sourceId) =>
      _box.put(bucketOf(kind), sourceId);

  Future<void> clear(ZKind kind) => _box.delete(bucketOf(kind));
}
