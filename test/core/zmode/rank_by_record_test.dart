import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';

List<({String id, String name})> pool(List<String> ids) =>
    [for (final i in ids) (id: i, name: i)];

SourceRecord Function(String) records(Map<String, SourceRecord> m) =>
    (id) => m[id] ?? (plays: 0, health: SourceHealth.ok, responseMs: null);

List<String> ids(List<({String id, String name})> l) =>
    [for (final s in l) s.id];

void main() {
  _pinsOverRanking();
  // THE safety property. A fresh install has no plays and no health, so the
  // ranker must hand back exactly what it was given — which is the order the
  // app already ships. If this ever fails, the change is no longer safe to
  // enable for everyone.
  test('with no history at all, the incoming order is returned untouched', () {
    final p = pool(['a', 'b', 'c', 'd']);
    expect(ids(rankByRecord(p, records({}))), ['a', 'b', 'c', 'd']);
  });

  test('more plays wins', () {
    final p = pool(['a', 'b', 'c']);
    final r = records({
      'a': (plays: 1, health: SourceHealth.ok, responseMs: null),
      'b': (plays: 9, health: SourceHealth.ok, responseMs: null),
      'c': (plays: 4, health: SourceHealth.ok, responseMs: null),
    });
    expect(ids(rankByRecord(p, r)), ['b', 'c', 'a']);
  });

  // THE bug this saturation fixes. Two sources that have both clearly worked
  // were ordered by a historical margin the user cannot see or change, and
  // speed could never close it because only more plays moved the order — and
  // the slower one was the one being tried.
  test('past the proven line, the faster of two veterans wins', () {
    final p = pool(['veteran', 'quick']);
    final r = records({
      'veteran': (plays: 50, health: SourceHealth.ok, responseMs: 9000),
      'quick': (plays: 49, health: SourceHealth.ok, responseMs: 50),
    });
    expect(ids(rankByRecord(p, r)), ['quick', 'veteran']);
  });

  test('below the proven line the count still decides, not speed', () {
    final p = pool(['once', 'never']);
    final r = records({
      'once': (plays: 1, health: SourceHealth.ok, responseMs: 9000),
      'never': (plays: 0, health: SourceHealth.ok, responseMs: 80),
    });
    // 1 play against 0 is a real difference; the trial slot is what gives the
    // unplayed one its turn, not the comparator.
    expect(ids(rankByRecord(p, r)), ['once', 'never']);
  });

  test('saturation is a ceiling, not a reset: 9 still beats 4', () {
    final p = pool(['four', 'nine']);
    final r = records({
      'four': (plays: 4, health: SourceHealth.ok, responseMs: null),
      'nine': (plays: 9, health: SourceHealth.ok, responseMs: null),
    });
    expect(ids(rankByRecord(p, r)), ['nine', 'four']);
  });

  // Clamping must not reintroduce the non-transitivity that nulls-last fixed.
  test('stays transitive across the proven line', () {
    final p = pool(['a', 'b', 'c']);
    final r = records({
      'a': (plays: 99, health: SourceHealth.ok, responseMs: 500),
      'b': (plays: 5, health: SourceHealth.ok, responseMs: 100),
      'c': (plays: 6, health: SourceHealth.ok, responseMs: null),
    });
    final once = ids(rankByRecord(p, r));
    // Same records, different input order -> same relative result.
    final again = ids(rankByRecord(pool(['c', 'a', 'b']), r));
    expect(again, once);
    expect(once, ['b', 'a', 'c']); // fastest proven, then 500ms, unknown last
  });

  test('same plays, the faster one wins', () {
    final p = pool(['slow', 'fast']);
    final r = records({
      'slow': (plays: 5, health: SourceHealth.ok, responseMs: 9000),
      'fast': (plays: 5, health: SourceHealth.ok, responseMs: 800),
    });
    expect(ids(rankByRecord(p, r)), ['fast', 'slow']);
  });

  test('a source with no timing does not break the ordering of ones that have',
      () {
    // The comparator used to skip the responseMs compare whenever either side
    // was null, which made it non-transitive: A < C < B while A > B.
    final p = pool(['a', 'c', 'b']);
    final r = records({
      'a': (plays: 5, health: SourceHealth.ok, responseMs: 100),
      'c': (plays: 5, health: SourceHealth.ok, responseMs: null),
      'b': (plays: 5, health: SourceHealth.ok, responseMs: 50),
    });
    // Measured sources rank among themselves by speed; the unmeasured one
    // goes last. No cycle, and the result does not depend on sort internals.
    expect(ids(rankByRecord(p, r)), ['b', 'a', 'c']);
  });

  test('a dead source sinks below a working one that has never played', () {
    final p = pool(['dead', 'fresh']);
    final r = records({
      'dead': (plays: 50, health: SourceHealth.dead, responseMs: null),
      'fresh': (plays: 0, health: SourceHealth.ok, responseMs: null),
    });
    expect(ids(rankByRecord(p, r)), ['fresh', 'dead']);
  });

  // Without this, a source installed today can never be tried, because it has
  // no plays and everything above it does — so it can never earn any. The top
  // 10 would freeze on whatever was installed first, permanently.
  test('an unplayed source is lifted into the cap when every slot is taken',
      () {
    final p = pool(['a', 'b', 'c', 'newbie']);
    final r = records({
      'a': (plays: 9, health: SourceHealth.ok, responseMs: null),
      'b': (plays: 8, health: SourceHealth.ok, responseMs: null),
      'c': (plays: 7, health: SourceHealth.ok, responseMs: null),
    });
    final out = ids(rankByRecord(p, r, cap: 3));
    expect(out.take(3), contains('newbie'));
    expect(out.first, 'a', reason: 'the best source keeps the top slot');
    expect(out.length, 4, reason: 'promotion moves an element, never copies it');
    expect(out.toSet().length, 4, reason: 'and never duplicates one');
  });

  test('the trial slot is not spent when an unplayed source already qualifies',
      () {
    // The pool must be bigger than the cap (so the length<=cap guard is
    // passed) and the unplayed source must already sit inside the cap, so
    // this actually exercises the "already spent" check instead of returning
    // before ever reaching it.
    final p = pool(['a', 'b', 'unplayed', 'extra']);
    final r = records({
      'a': (plays: 9, health: SourceHealth.ok, responseMs: null),
      'b': (plays: 8, health: SourceHealth.ok, responseMs: null),
    });
    expect(ids(rankByRecord(p, r, cap: 3)), ['a', 'b', 'unplayed', 'extra']);
  });

  test('a dead source is never promoted into the trial slot', () {
    final p = pool(['a', 'b', 'c', 'deadnew']);
    final r = records({
      'a': (plays: 9, health: SourceHealth.ok, responseMs: null),
      'b': (plays: 8, health: SourceHealth.ok, responseMs: null),
      'c': (plays: 7, health: SourceHealth.ok, responseMs: null),
      'deadnew': (plays: 0, health: SourceHealth.dead, responseMs: null),
    });
    expect(ids(rankByRecord(p, r, cap: 3)).take(3), isNot(contains('deadnew')));
  });

  test('nothing is dropped — ranking reorders, the cap is applied elsewhere',
      () {
    // The top `cap` sources need real plays, otherwise every one of them
    // reads as unplayed and the "slot already spent" guard returns before
    // the promotion (remove+insert) branch ever runs.
    final p = pool(['a', 'b', 'c', 'd', 'e']);
    final r = records({
      'a': (plays: 5, health: SourceHealth.ok, responseMs: null),
      'b': (plays: 4, health: SourceHealth.ok, responseMs: null),
    });
    expect(rankByRecord(p, r, cap: 2).length, 5);
  });
}

// Dragging one favourite must not stop the app ranking everything else.
// `sweepCandidates` composes these two: rank first, then lay the pins on top.
void _pinsOverRanking() {
  test('a pinned source leads while the rest stay ranked', () {
    final p = pool(['a', 'b', 'c', 'fav']);
    final r = records({
      'a': (plays: 9, health: SourceHealth.ok, responseMs: null),
      'b': (plays: 5, health: SourceHealth.ok, responseMs: null),
      'c': (plays: 1, health: SourceHealth.ok, responseMs: null),
      'fav': (plays: 0, health: SourceHealth.ok, responseMs: null),
    });
    // What sweepCandidates does, in the same order.
    final ranked = rankByRecord(p, r);
    final out = applySourceOrder(ranked, ['fav']);
    expect(out.first.id, 'fav', reason: 'the drag wins');
    expect(
      [for (final s in out.skip(1)) s.id],
      ['a', 'b', 'c'],
      reason: 'everything untouched is still ranked, not frozen in pool order',
    );
  });

  test('with nothing pinned the ranking is untouched', () {
    final p = pool(['a', 'b']);
    final r = records({
      'b': (plays: 9, health: SourceHealth.ok, responseMs: null),
    });
    final out = applySourceOrder(rankByRecord(p, r), const []);
    expect([for (final s in out) s.id], ['b', 'a']);
  });
}
