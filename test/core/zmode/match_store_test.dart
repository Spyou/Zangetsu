import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  late Directory dir;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  const allanime = SourceMatch(
      sourceId: 'allanime', showUrl: 'https://a/fma', showId: 'fma',
      showTitle: 'Fullmetal Alchemist: Brotherhood', pinned: false);
  const hianime = SourceMatch(
      sourceId: 'hianime', showUrl: 'https://h/fma', showId: 'fma-h',
      showTitle: 'FMA', pinned: false);

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
    expect(store.get(fma, 'allanime'), isNull);
    await store.save(fma, allanime);
    expect(store.get(fma, 'allanime')?.showUrl, 'https://a/fma');
    await Hive.close();
    Hive.init(dir.path);
    store = await MatchStore.open();
    expect(store.get(fma, 'allanime')?.sourceId, 'allanime');
    expect(store.get(fma, 'allanime')?.pinned, isFalse);
  });

  test('per-source matches do not collide', () async {
    final store = await MatchStore.open();
    await store.save(fma, allanime);
    await store.save(fma, hianime);
    expect(store.get(fma, 'allanime')?.showId, 'fma');
    expect(store.get(fma, 'hianime')?.showId, 'fma-h');
  });

  test('pinning source A does not affect source B', () async {
    final store = await MatchStore.open();
    await store.pin(fma, allanime);
    await store.save(fma, hianime);
    expect(store.get(fma, 'allanime')?.pinned, isTrue);
    expect(store.get(fma, 'hianime')?.pinned, isFalse);
    // A later guess for A must not overwrite its pin...
    const wrongGuess = SourceMatch(
        sourceId: 'allanime', showUrl: 'https://a/wrong', showId: 'wrong',
        showTitle: 'wrong', pinned: false);
    await store.save(fma, wrongGuess);
    expect(store.get(fma, 'allanime')?.showId, 'fma');
    // ...while B, never pinned, still takes guesses normally.
    expect(store.get(fma, 'hianime')?.showId, 'fma-h');
  });

  test('a pin replaces an earlier pin for the same source, and forget clears just that source',
      () async {
    final store = await MatchStore.open();
    await store.pin(fma, allanime);
    await store.save(fma, hianime);
    const fixed = SourceMatch(
        sourceId: 'allanime', showUrl: 'https://a/fixed', showId: 'fixed',
        showTitle: 'FMA:B', pinned: true);
    await store.pin(fma, fixed);
    expect(store.get(fma, 'allanime')?.showId, 'fixed');
    await store.forget(fma, 'allanime');
    expect(store.get(fma, 'allanime'), isNull);
    // Forgetting one source leaves the other's match alone.
    expect(store.get(fma, 'hianime')?.showId, 'fma-h');
  });

  test('selectedSource round-trips and survives reopen', () async {
    var store = await MatchStore.open();
    expect(store.selectedSource(fma), isNull);
    await store.selectSource(fma, 'hianime');
    expect(store.selectedSource(fma), 'hianime');
    await Hive.close();
    Hive.init(dir.path);
    store = await MatchStore.open();
    expect(store.selectedSource(fma), 'hianime');
  });

  test('a selection key never collides with a match key', () async {
    final store = await MatchStore.open();
    await store.save(fma, allanime);
    await store.selectSource(fma, 'hianime');
    expect(store.get(fma, 'allanime')?.sourceId, 'allanime');
    expect(store.selectedSource(fma), 'hianime');
  });

  test('an old bare-key entry (pre-per-source) is ignored, not thrown on', () async {
    final store = await MatchStore.open();
    final box = Hive.box<Map>(MatchStore.boxName);
    // Simulates data written before this store keyed matches by source too.
    await box.put(fma.key, allanime.toMap());
    expect(store.get(fma, 'allanime'), isNull);
    expect(store.selectedSource(fma), isNull);
  });

  test('malformed optional fields (wrong types) deserialize to empty strings, not throw',
      () async {
    final store = await MatchStore.open();
    final box = Hive.box<Map>(MatchStore.boxName);
    await box.put('${fma.key}@test', {
      'sourceId': 'test',
      'showUrl': 'https://test.com',
      'showId': 123, // int instead of String
      'showTitle': 456, // int instead of String
      'pinned': false,
    });
    final match = store.get(fma, 'test');
    expect(match, isNotNull);
    expect(match?.sourceId, 'test');
    expect(match?.showId, '');
    expect(match?.showTitle, '');
  });

  test('missing required field (sourceId) returns null, not throw', () async {
    final store = await MatchStore.open();
    final box = Hive.box<Map>(MatchStore.boxName);
    await box.put('${fma.key}@test', {
      'showUrl': 'https://test.com',
      'showId': 'id',
      'showTitle': 'title',
      'pinned': false,
    });
    expect(store.get(fma, 'test'), isNull);
  });

  test('a malformed selection value is ignored, not thrown on', () async {
    final store = await MatchStore.open();
    final box = Hive.box<Map>(MatchStore.boxName);
    await box.put('sel:${fma.key}', {'sourceId': 42}); // wrong type
    expect(store.selectedSource(fma), isNull);
  });
}
