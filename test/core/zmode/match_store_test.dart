import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  late Directory dir;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  const guess = SourceMatch(
      sourceId: 'allanime', showUrl: 'https://a/fma', showId: 'fma',
      showTitle: 'Fullmetal Alchemist: Brotherhood', pinned: false);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('match_store');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('misses are null, saves round-trip and survive reopen', () async {
    var store = await MatchStore.open();
    expect(store.get(fma), isNull);
    await store.save(fma, guess);
    expect(store.get(fma)?.showUrl, 'https://a/fma');
    await Hive.close();
    Hive.init(dir.path);
    store = await MatchStore.open();
    expect(store.get(fma)?.sourceId, 'allanime');
    expect(store.get(fma)?.pinned, isFalse);
  });

  test('a pin is never overwritten by a later guess', () async {
    final store = await MatchStore.open();
    await store.pin(fma, guess);
    const other = SourceMatch(
        sourceId: 'hianime', showUrl: 'https://h/x', showId: 'x',
        showTitle: 'wrong', pinned: false);
    await store.save(fma, other);
    expect(store.get(fma)?.sourceId, 'allanime');
    expect(store.get(fma)?.pinned, isTrue);
  });

  test('a pin replaces an earlier pin, and forget clears', () async {
    final store = await MatchStore.open();
    await store.pin(fma, guess);
    const fixed = SourceMatch(
        sourceId: 'hianime', showUrl: 'https://h/fma', showId: 'fma',
        showTitle: 'FMA:B', pinned: true);
    await store.pin(fma, fixed);
    expect(store.get(fma)?.sourceId, 'hianime');
    await store.forget(fma);
    expect(store.get(fma), isNull);
  });

  test('malformed optional fields (wrong types) deserialize to empty strings, not throw',
      () async {
    final store = await MatchStore.open();
    // Put a map with int values for showId/showTitle, simulating upgrade-stale data
    final box = Hive.box<Map>(MatchStore.boxName);
    await box.put(fma.key, {
      'sourceId': 'test',
      'showUrl': 'https://test.com',
      'showId': 123, // int instead of String
      'showTitle': 456, // int instead of String
      'pinned': false,
    });
    // Should deserialize gracefully with empty strings
    final match = store.get(fma);
    expect(match, isNotNull);
    expect(match?.sourceId, 'test');
    expect(match?.showId, '');
    expect(match?.showTitle, '');
  });

  test('missing required field (sourceId) returns null, not throw', () async {
    final store = await MatchStore.open();
    final box = Hive.box<Map>(MatchStore.boxName);
    await box.put(fma.key, {
      'showUrl': 'https://test.com',
      'showId': 'id',
      'showTitle': 'title',
      'pinned': false,
    });
    // Should return null, not throw
    expect(store.get(fma), isNull);
  });
}
