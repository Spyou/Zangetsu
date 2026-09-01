import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import 'zmode_ids.dart';

/// Which source plays Z Mode titles, remembered GLOBALLY per kind.
///
/// Not per title: choosing a source is a statement about how you want to
/// watch, not about one show. Picking one on a title's Detail screen changes
/// it everywhere for that kind, and the next title of that kind opens already
/// pointing at it.
///
/// The reason this exists as a stored preference rather than something
/// derived: a remembered id is a synchronous read, so a Detail screen knows
/// its source on the first frame. Deriving the selection by searching sources
/// (what this replaced) meant the row could not name anything until a network
/// sweep finished, on every title.
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

  String? get(ZKind kind) {
    final v = _box.get(bucketOf(kind))?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> set(ZKind kind, String sourceId) =>
      _box.put(bucketOf(kind), sourceId);

  Future<void> clear(ZKind kind) => _box.delete(bucketOf(kind));
}
