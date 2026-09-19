import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../playback/source_health_store.dart';
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
  // ── How many sources Auto Resolve is allowed to try ─────────────────────

  static String _capKey(ZKind kind) => '${bucketOf(kind)}:cap';

  /// Smallest useful sweep. Below three, one dead source and one slow one is
  /// the whole budget and titles start failing that a fourth would have found.
  static const int minCap = 3;

  /// How many sources the sweep may walk. Defaults to [kAutoResolveCap].
  ///
  /// Stored as a one-element list because this box is a `Box<List>` — the same
  /// box the orders live in, so there is one entry in settings backup rather
  /// than two. Clamped on read as well as write: a value left by an older or
  /// newer build must not be able to switch the cap off or shrink it to one.
  int cap(ZKind kind) {
    final raw = _box.get(_capKey(kind));
    final first = (raw == null || raw.isEmpty) ? null : raw.first;
    final n = first is int ? first : int.tryParse('$first');
    return (n ?? kAutoResolveCap).clamp(minCap, kAutoResolveCap);
  }

  Future<void> setCap(ZKind kind, int n) =>
      _box.put(_capKey(kind), [n.clamp(minCap, kAutoResolveCap)]);

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
  // Always unique by id: duplicate candidates (same sourceId from two repos
  // when the runtime hasn't loaded either) used to reach ReorderableListView
  // / TV rows keyed on id and assert. First occurrence wins.
  if (order.isEmpty) {
    final seen = <String>{};
    return [for (final c in candidates) if (seen.add(c.id)) c];
  }
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

/// How many sources Auto Resolve will try before giving up.
///
/// A sweep walks candidates one at a time and stops at the first hit, so the
/// cap costs nothing on the common case — it bounds the miss, which is the
/// case that used to walk every installed source. The number is the same one
/// the Source Priority screen has advised in prose since it was written.
const int kAutoResolveCap = 10;

/// Plays past this many stop separating two sources.
///
/// The tally only ever goes up, so comparing raw counts froze the order on
/// historical margins that mean nothing today: a source played 50 times sat
/// above one played 49 times forever, even when the 49 answered 180x faster,
/// because only more plays could move it and the slower one was the one being
/// tried. Once both have clearly worked, let today's speed decide. Below the
/// line the count still counts — 1 play against 0 is a real difference, and
/// that is what the trial slot exists to resolve.
const int kProvenPlays = 5;

/// One source's track record, as the ranker sees it.
typedef SourceRecord = ({int plays, SourceHealth health, int? responseMs});

/// [pool] reordered by what has actually worked on this device.
///
/// STABLE: sources the records cannot separate keep the order they came in,
/// so with no history at all this returns [pool] untouched — which is exactly
/// today's behaviour, and the reason this can be turned on for everyone
/// rather than hidden behind a setting.
///
/// Nothing is dropped. The cap is applied by the caller, because the picker
/// and pin lookups need the whole list and only the sweep is bounded.
///
/// [trialSlots] keeps room inside the cap for a source that has never played.
/// Ranking purely on history is self-fulfilling: a source installed today has
/// no plays, so it never gets tried, so it never earns any. One slot is enough
/// to keep the list from freezing on whatever happened to be installed first.
List<({String id, String name})> rankByRecord(
  List<({String id, String name})> pool,
  SourceRecord Function(String id) recordOf, {
  int trialSlots = 1,
  int cap = kAutoResolveCap,
}) {
  // Decorate-sort-undecorate on the incoming index, so ties keep pool order.
  final indexed = [
    for (var i = 0; i < pool.length; i++) (at: i, s: pool[i], r: recordOf(pool[i].id)),
  ];
  indexed.sort((a, b) {
    // Dead sinks below everything, however good its history was. A source
    // that is failing right now cannot play this episode, and its 50 past
    // plays are what would otherwise keep it at the top of the sweep.
    final aDead = a.r.health == SourceHealth.dead;
    final bDead = b.r.health == SourceHealth.dead;
    if (aDead != bDead) return aDead ? 1 : -1;
    // Saturated at [kProvenPlays]: proven is proven, and the raw tally past
    // that is history rather than information. Clamping is monotonic, so the
    // comparator stays transitive.
    final ap = a.r.plays.clamp(0, kProvenPlays);
    final bp = b.r.plays.clamp(0, kProvenPlays);
    if (ap != bp) return bp.compareTo(ap);
    // A source with no timing yet is not "equal speed" — it is unknown, and
    // treating unknown as equal is what made this comparator non-transitive:
    // null-vs-measured fell through to pool index while measured-vs-measured
    // did not, so A < C < B could coexist with A > B. Unknown sorts last, and
    // two unknowns still compare equal and fall through to index below, which
    // is what keeps the no-history case returning the input untouched.
    final am = a.r.responseMs, bm = b.r.responseMs;
    if (am != bm) {
      if (am == null) return 1;
      if (bm == null) return -1;
      return am.compareTo(bm);
    }
    return a.at.compareTo(b.at);
  });
  final ranked = [for (final e in indexed) e.s];
  // cap < 2 leaves no room to insert a trial ahead of the top slot without
  // evicting it — the top source keeps its place instead of being bumped.
  if (trialSlots <= 0 || cap < 2 || ranked.length <= cap) return ranked;

  // Already an unproven source inside the cap? Then the slot is spent and
  // promoting another would push out a source that has earned its place.
  final inCap = ranked.take(cap);
  if (inCap.any((s) => recordOf(s.id).plays == 0)) return ranked;

  ({String id, String name})? promote;
  for (final s in ranked.skip(cap)) {
    final r = recordOf(s.id);
    if (r.plays == 0 && r.health != SourceHealth.dead) {
      promote = s;
      break;
    }
  }
  if (promote == null) return ranked;

  // Into the LAST slot inside the cap: the trial is worth a try, not a
  // promotion over sources that have actually worked.
  final out = [...ranked]..remove(promote);
  out.insert(cap - 1, promote);
  return out;
}
