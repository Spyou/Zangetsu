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

  /// One bucket for everything that plays, separate ones for reading.
  ///
  /// Anime and Movies/TV used to be split. They share one installed pool, so
  /// the split only ever meant keeping two orders of the same sources — twice
  /// the list to maintain for a distinction most people don't draw. Manga and
  /// novel stay their own because they genuinely are different sources.
  static String bucketOf(ZKind kind) => switch (kind) {
    ZKind.manga => 'manga',
    ZKind.novel => 'novel',
    _ => 'video',
  };

  /// The pre-merge keys, so an order set before the split went away is still
  /// honoured instead of silently resetting to nothing.
  static const List<String> _legacyVideoKeys = ['anime', 'movie'];

  List? _rawFor(String key, {required bool video, String suffix = ''}) {
    final direct = _box.get('$key$suffix');
    if (direct != null || !video) return direct;
    for (final legacy in _legacyVideoKeys) {
      final old = _box.get('$legacy$suffix');
      if (old != null) return old;
    }
    return null;
  }

  /// The saved priority order for [kind]'s bucket, as source ids. Empty when
  /// the user has never reordered this bucket.
  List<String> get(ZKind kind) {
    final bucket = bucketOf(kind);
    final raw = _rawFor(bucket, video: bucket == 'video');
    if (raw == null) return const [];
    return raw.whereType<String>().toList();
  }

  Future<void> set(ZKind kind, List<String> orderedIds) =>
      _box.put(bucketOf(kind), orderedIds);

  Future<void> clear(ZKind kind) => _box.delete(bucketOf(kind));

  // ── Sources the user has switched off for Auto Resolve ──────────────────
  //
  // Kept in the same box under a suffixed key rather than a second box: it is
  // the same setting seen from the other end (where a source sits in the sweep
  // order, versus not sitting in it at all), and one box means one entry in
  // SettingsBackup.
  //
  // "Off" means the SWEEP skips it. It stays installed, keeps its own
  // settings, and is still offered in the per-title picker — turning a source
  // off is not uninstalling it, and someone who picks it by hand for one show
  // should still get it.
  static String _offKey(ZKind kind) => '${bucketOf(kind)}:off';

  Set<String> excluded(ZKind kind) {
    final bucket = bucketOf(kind);
    final raw = _rawFor(bucket, video: bucket == 'video', suffix: ':off');
    if (raw == null) return const {};
    return raw.whereType<String>().toSet();
  }

  Future<void> setExcluded(ZKind kind, Set<String> ids) =>
      _box.put(_offKey(kind), ids.toList());

  Future<void> exclude(ZKind kind, String id) =>
      setExcluded(kind, {...excluded(kind), id});

  Future<void> include(ZKind kind, String id) =>
      setExcluded(kind, {...excluded(kind)}..remove(id));
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

/// The sources Auto Resolve sweeps, in order: everything installed except the
/// ones the user switched off.
///
/// No default limit. An earlier version used the first ten until the user said
/// otherwise, which presented a preference nobody had expressed — with a
/// hundred sources installed, those ten were whatever happened to sort first.
/// Speed comes from the order (a good source first ends the sweep on the first
/// try), from remembered misses (most candidates answer in under a
/// millisecond), and from the sweep's own time budget — none of which require
/// claiming a choice the user never made.
///
/// Pure so the resolver and the Source Priority screen can't disagree about
/// what is on — a screen showing one thing while the sweep did another is the
/// kind of bug nobody reports because they assume they misread it.
List<({String id, String name})> activeSources(
  List<({String id, String name})> ordered, {
  required Set<String> excluded,
}) => [
  for (final s in ordered)
    if (!excluded.contains(s.id)) s,
];
