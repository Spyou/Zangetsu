import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

void main() {
  late Directory dir;
  late ZSourcePrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zsource');
    Hive.init(dir.path);
    prefs = await ZSourcePrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('starts with no pick for any kind', () {
    for (final k in ZKind.values) {
      expect(prefs.get(k), isNull);
    }
  });

  test('a pick round-trips and survives a reopen', () async {
    await prefs.set(ZKind.anime, 'ani:1');
    expect(prefs.get(ZKind.anime), 'ani:1');

    await Hive.close();
    Hive.init(dir.path);
    prefs = await ZSourcePrefs.open();
    expect(prefs.get(ZKind.anime), 'ani:1');
  });

  test('kinds do not bleed into each other', () async {
    await prefs.set(ZKind.anime, 'ani:1');
    await prefs.set(ZKind.manga, 'mihon:2');
    await prefs.set(ZKind.novel, 'lnr:3');

    // The whole point: choosing an anime source must not turn up in manga.
    expect(prefs.get(ZKind.anime), 'ani:1');
    expect(prefs.get(ZKind.manga), 'mihon:2');
    expect(prefs.get(ZKind.novel), 'lnr:3');
  });

  test('anime, movie and tv share one pick, because they share one pool', () async {
    await prefs.set(ZKind.movie, 'cs:4K HDHUB');
    // candidatesForKind offers the same streaming sources for all three, so a
    // separate pick per kind would just be three ways to say the same thing.
    expect(prefs.get(ZKind.anime), 'cs:4K HDHUB');
    expect(prefs.get(ZKind.tv), 'cs:4K HDHUB');
    expect(prefs.get(ZKind.movie), 'cs:4K HDHUB');
    expect(prefs.get(ZKind.manga), isNull);
  });

  test('clearing one kind leaves the others alone', () async {
    await prefs.set(ZKind.anime, 'ani:1');
    await prefs.set(ZKind.manga, 'mihon:2');
    await prefs.clear(ZKind.anime);
    expect(prefs.get(ZKind.anime), isNull);
    expect(prefs.get(ZKind.manga), 'mihon:2');
  });
}
