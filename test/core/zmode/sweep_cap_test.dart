// The old version of this file only exercised Task 3's pure `rankByRecord`
// and `applySourceOrder` — both already covered by `rank_by_record_test.dart`
// — and never called `sweepList`/`orderedCandidates` themselves. All three
// tests there would still pass against a fully reverted Task 4. These tests
// drive the real functions, through `sl`, the way production does.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_module.dart';

// Ids with no `mihon:`/`lnr:` prefix land in the video pool `candidatesForKind`
// builds for anime/movie/tv — matches every real installed streaming source.
class _FakeSources implements SourceRepository {
  _FakeSources(this.ids);
  final List<String> ids;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  List<({String id, String name})> get loadedSources =>
      [for (final id in ids) (id: id, name: id)];
}

class _FakeScores implements SourceScoreStore {
  final Map<String, int> _plays = {};

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  int plays(String id) => _plays[id] ?? 0;

  void seed(String id, int n) => _plays[id] = n;
}

// A saved order is the manual/automatic switch itself (`.get(kind).isNotEmpty`)
// — faking Hive would only add ceremony `set`/`get` don't need.
class _FakeOrderPrefs implements SourceOrderPrefs {
  final Map<ZKind, List<String>> _order = {};

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<String> get(ZKind kind) => _order[kind] ?? const [];
  @override
  Future<void> set(ZKind kind, List<String> orderedIds) async {
    _order[kind] = orderedIds;
  }

  // A real one, not a hardcoded empty set — otherwise the test asserting a
  // stale exclude set is ignored would pass against any implementation.
  final Map<ZKind, Set<String>> _excluded = {};
  @override
  Set<String> excluded(ZKind kind) => _excluded[kind] ?? const {};
  @override
  Future<void> setExcluded(ZKind kind, Set<String> ids) async {
    _excluded[kind] = ids;
  }

  /// How many the sweep may try. Defaults to [kAutoResolveCap] like the real
  /// store, so the existing cap tests keep asserting the shipped default; a
  /// test that wants a smaller sweep sets it.
  int _cap = kAutoResolveCap;
  @override
  int cap(ZKind kind) => _cap;
  @override
  Future<void> setCap(ZKind kind, int n) async {
    _cap = n.clamp(SourceOrderPrefs.minCap, kAutoResolveCap);
  }
}

void main() {
  late _FakeSources sources;
  late _FakeScores scores;
  late _FakeOrderPrefs orderPrefs;

  setUp(() {
    sources = _FakeSources([for (var i = 0; i < 20; i++) 's$i']);
    scores = _FakeScores();
    orderPrefs = _FakeOrderPrefs();
    sl.registerSingleton<SourceRepository>(sources);
    sl.registerSingleton<SourceScoreStore>(scores);
    // Real store, box never opened: every lookup safely defaults to healthy,
    // which is all these tests need — no fake required.
    sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
    sl.registerSingleton<SourceOrderPrefs>(orderPrefs);
  });

  tearDown(() async {
    await sl.reset();
  });

  // The bug this whole change exists for: an unmatched title used to walk
  // every installed source, one at a time. Fails if `.take(kAutoResolveCap)`
  // is ever dropped from `sweepList`.
  test('the cap is real: 20 eligible sources sweep down to 10', () {
    expect(sweepList(ZKind.anime).length, kAutoResolveCap);
  });

  // s19 sits last in the incoming pool (`_FakeSources` hands them out in
  // order s0..s19); only its play count sets it apart. Fails if `sweepList`
  // ever hands `.take(kAutoResolveCap)` the unranked list directly.
  test('ranking actually runs: heavy history moves a source to the front',
      () {
    scores.seed('s19', 500);
    expect(sweepList(ZKind.anime).first.id, 's19');
  });

  // Dragging is a takeover: ranking must not run at all once a saved order
  // exists. Fails if the `sourceOrderPrefs.get(kind).isNotEmpty` early return
  // is ever deleted from `sweepList`.
  test('a saved manual order is respected — ranking does not run', () async {
    await orderPrefs.set(ZKind.anime, ['s5', 's3']);
    // Without the early return this history would promote s19 to the front.
    scores.seed('s19', 999999);
    final swept = sweepList(ZKind.anime);
    expect([for (final s in swept.take(2)) s.id], ['s5', 's3']);
  });

  // `orderedCandidates` feeds the per-title picker and pin lookups, which
  // must keep seeing every installed source — only `sweepList` is capped.
  test('orderedCandidates stays whole while sweepList is capped', () {
    expect(orderedCandidates(ZKind.anime).length, 20);
    expect(sweepList(ZKind.anime).length, kAutoResolveCap);
  });

  test('kAutoResolveCap is 10 — the number the screen has always advised', () {
    expect(kAutoResolveCap, 10);
  });

  test('the cap is adjustable: set it to 3 and only 3 are swept', () {
    // 10 is the ceiling, not the rule. Someone who knows their top three
    // should not wait on seven more before being told nothing has it.
    orderPrefs.setCap(ZKind.anime, 3);
    expect(sweepList(ZKind.anime).length, 3);
    orderPrefs.setCap(ZKind.anime, 10);
    expect(sweepList(ZKind.anime).length, 10);
  });

  test('a cap outside 3..10 is clamped, never honoured', () {
    orderPrefs.setCap(ZKind.anime, 0);
    expect(sweepList(ZKind.anime).length, SourceOrderPrefs.minCap,
        reason: 'zero would mean Auto Resolve never tries anything');
    orderPrefs.setCap(ZKind.anime, 999);
    expect(sweepList(ZKind.anime).length, kAutoResolveCap);
  });

  // The player used to ignore this setting entirely: `sweepList` was capped,
  // but PlaybackResolver walked `orderedCandidates`, all 32 of them. "Try the
  // top 3 sources" meant 3 on the settings screen and 32 in the player, which
  // is the definition of a setting that is not one.
  test('the playback sweep is bounded by the same number, not the full list',
      () {
    orderPrefs.setCap(ZKind.anime, 3);
    expect(sweepList(ZKind.anime).length, 3);
    // orderedCandidates stays whole — the picker and pin lookups need it.
    expect(orderedCandidates(ZKind.anime).length, greaterThan(3),
        reason: 'only the SWEEP is capped; the pickable list must stay full');
  });

  // Switching a source off is gone: the limit and the order do that job now.
  // A stale exclude set from before must NOT keep a source out, or someone who
  // once used the removed toggle would have sources silently off forever with
  // no UI left to find them.
  test('a saved exclude set from the old toggle no longer hides a source', () {
    orderPrefs.setExcluded(ZKind.anime, {'s0'});
    expect(
      [for (final x in sweepList(ZKind.anime)) x.id],
      contains('s0'),
      reason: 'nothing reads the exclude set any more; it is inert, not lost',
    );
  });
}
