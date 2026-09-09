// Switching a source off means Auto Resolve stops SWEEPING it. It stays
// installed, keeps its settings, and is still offered in the per-title picker
// — turning a source off is not uninstalling it, and someone who picks it by
// hand for one show should still get it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  late Directory dir;
  late SourceOrderPrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source-order-off');
    Hive.init(dir.path);
    prefs = await SourceOrderPrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('nothing is off to begin with', () {
    expect(prefs.excluded(ZKind.anime), isEmpty);
  });

  test('a source can be switched off and back on', () async {
    await prefs.exclude(ZKind.anime, 'animekai');
    expect(prefs.excluded(ZKind.anime), {'animekai'});
    await prefs.include(ZKind.anime, 'animekai');
    expect(prefs.excluded(ZKind.anime), isEmpty);
  });

  test('anime and movies share one list; reading kinds keep their own',
      () async {
    // They were split. The same installed pool serves both, so it only ever
    // meant two orders of the same sources — twice the list to keep straight
    // for a distinction most people don't draw. Manga and novel stay separate
    // because those genuinely are different sources.
    await prefs.exclude(ZKind.anime, 'hdhub4u');
    expect(prefs.excluded(ZKind.movie), {'hdhub4u'});
    expect(prefs.excluded(ZKind.manga), isEmpty);
    await prefs.exclude(ZKind.manga, 'mihon:1');
    expect(prefs.excluded(ZKind.anime), {'hdhub4u'});
    expect(prefs.excluded(ZKind.manga), {'mihon:1'});
  });

  test('an order saved before the split went away is still honoured', () async {
    // Written under the old per-kind key. Falling back to it is the
    // difference between keeping someone's order and silently resetting it.
    await Hive.box<List>(SourceOrderPrefs.boxName).put('anime', ['b', 'a']);
    expect(prefs.get(ZKind.anime), ['b', 'a']);
    expect(prefs.get(ZKind.movie), ['b', 'a']);
    // …until a new one is saved, which takes over.
    await prefs.set(ZKind.anime, ['a', 'b']);
    expect(prefs.get(ZKind.movie), ['a', 'b']);
  });

  test('the off-list survives a reorder, and order survives a switch-off',
      () async {
    // They live in one box under different keys; writing one must not clear
    // the other.
    await prefs.set(ZKind.anime, ['a', 'b', 'c']);
    await prefs.exclude(ZKind.anime, 'b');
    expect(prefs.get(ZKind.anime), ['a', 'b', 'c']);
    expect(prefs.excluded(ZKind.anime), {'b'});
  });

  test('reset clears both', () async {
    await prefs.set(ZKind.anime, ['a', 'b']);
    await prefs.exclude(ZKind.anime, 'b');
    await prefs.clear(ZKind.anime);
    await prefs.setExcluded(ZKind.anime, const {});
    expect(prefs.get(ZKind.anime), isEmpty);
    expect(prefs.excluded(ZKind.anime), isEmpty);
  });

  group('what Auto Resolve actually sweeps', () {
    List<({String id, String name})> pool(int n) =>
        [for (var i = 1; i <= n; i++) (id: 's$i', name: 'S$i')];

    test('untouched, EVERY source is used', () {
      // No invented default. An earlier version used the first ten until the
      // user said otherwise, which presented a preference nobody had
      // expressed — with a hundred installed, those ten were whatever
      // happened to sort first.
      final on = activeSources(pool(30), excluded: const {});
      expect(on.length, 30);
      expect(on.first.id, 's1');
      expect(on.last.id, 's30');
    });

    test('switched-off ones are dropped, order otherwise kept', () {
      final on = activeSources(pool(6), excluded: const {'s2', 's5'});
      expect(on.map((s) => s.id), ['s1', 's3', 's4', 's6']);
    });

    test('switching everything off leaves nothing to sweep', () {
      final on = activeSources(
        pool(3),
        excluded: const {'s1', 's2', 's3'},
      );
      expect(on, isEmpty);
    });
  });
}
