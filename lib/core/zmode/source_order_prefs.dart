import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import 'zmode_ids.dart';

/// The user's preferred sweep order of installed sources, per content type —
/// separate lists for Anime and Movies/TV (they share one installed pool, but
/// a source that's great for one can return nothing for the other, so which
/// goes first should differ). Manga/novel get their own buckets too, for
/// symmetry, though only Anime/Movies-TV are exposed in Settings today.
///
/// Only the ids the user has actually reordered are stored; anything
/// installed but never touched keeps its natural order, appended after.
class SourceOrderPrefs {
  SourceOrderPrefs._(this._box);
  final Box<List> _box;

  static const String boxName = 'zmode_source_order';

  static Future<SourceOrderPrefs> open() async =>
      SourceOrderPrefs._(await openBoxSafely<List>(boxName));

  static String bucketOf(ZKind kind) => switch (kind) {
    ZKind.manga => 'manga',
    ZKind.novel => 'novel',
    ZKind.movie || ZKind.tv => 'movie',
    ZKind.anime => 'anime',
  };

  /// The saved priority order for [kind]'s bucket, as source ids. Empty when
  /// the user has never reordered this bucket.
  List<String> get(ZKind kind) {
    final raw = _box.get(bucketOf(kind));
    if (raw == null) return const [];
    return raw.whereType<String>().toList();
  }

  Future<void> set(ZKind kind, List<String> orderedIds) =>
      _box.put(bucketOf(kind), orderedIds);

  Future<void> clear(ZKind kind) => _box.delete(bucketOf(kind));
}

/// Reorders [candidates] to match the user's saved [order] (a list of source
/// ids), keeping anything not in [order] in its original relative position
/// after the ordered ones. Pure, so the priority screen and the resolver can
/// share it without either depending on the other.
List<({String id, String name})> applySourceOrder(
  List<({String id, String name})> candidates,
  List<String> order,
) {
  if (order.isEmpty) return candidates;
  final byId = {for (final c in candidates) c.id: c};
  final ordered = <({String id, String name})>[];
  for (final id in order) {
    final c = byId.remove(id);
    if (c != null) ordered.add(c);
  }
  ordered.addAll(byId.values);
  return ordered;
}
