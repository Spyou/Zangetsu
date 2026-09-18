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

  test('same plays, the faster one wins', () {
    final p = pool(['slow', 'fast']);
    final r = records({
      'slow': (plays: 5, health: SourceHealth.ok, responseMs: 9000),
      'fast': (plays: 5, health: SourceHealth.ok, responseMs: 800),
    });
    expect(ids(rankByRecord(p, r)), ['fast', 'slow']);
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
  });

  test('the trial slot is not spent when an unplayed source already qualifies',
      () {
    final p = pool(['played', 'unplayed']);
    final r = records({
      'played': (plays: 9, health: SourceHealth.ok, responseMs: null),
    });
    expect(ids(rankByRecord(p, r, cap: 3)), ['played', 'unplayed']);
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
    final p = pool(['a', 'b', 'c', 'd', 'e']);
    expect(rankByRecord(p, records({}), cap: 2).length, 5);
  });
}
