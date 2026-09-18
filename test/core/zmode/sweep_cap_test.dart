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

  @override
  Set<String> excluded(ZKind kind) => const {};
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
}
