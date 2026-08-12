import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/reader_overrides.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reader_overrides');
    Hive.init(dir.path);
    await ReaderPrefs.init();
    await ReaderOverrideStore.init();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'empty store: effective mode/fit fall straight through to the global '
    "prefs — today's behavior, unchanged",
    () async {
      final prefs = ReaderPrefs();
      await prefs.setDirection('rtl');
      await prefs.setFitMode('width');
      final store = ReaderOverrideStore();

      expect(store.modeOverride('src', 'show'), isNull);
      expect(store.fitOverride('src', 'show'), isNull);
      expect(store.effectiveMode('src', 'show', prefs), 'rtl');
      expect(store.effectiveFit('src', 'show', prefs), 'width');
    },
  );

  test(
    'setting a mode/fit override makes it effective, over the global default',
    () async {
      final prefs = ReaderPrefs();
      await prefs.setDirection('ltr');
      await prefs.setFitMode('contain');
      final store = ReaderOverrideStore();

      await store.setModeOverride('src', 'show', 'rtl');
      await store.setFitOverride('src', 'show', 'height');

      expect(store.effectiveMode('src', 'show', prefs), 'rtl');
      expect(store.effectiveFit('src', 'show', prefs), 'height');
    },
  );

  test('clearing an override (null) falls back to the global default again', () async {
    final prefs = ReaderPrefs();
    await prefs.setDirection('ltr');
    final store = ReaderOverrideStore();

    await store.setModeOverride('src', 'show', 'vertical');
    expect(store.effectiveMode('src', 'show', prefs), 'vertical');

    await store.setModeOverride('src', 'show', null);
    expect(store.modeOverride('src', 'show'), isNull);
    expect(store.effectiveMode('src', 'show', prefs), 'ltr');
  });

  test('two different sourceId:showId keys are independent', () async {
    final prefs = ReaderPrefs();
    await prefs.setDirection('ltr');
    final store = ReaderOverrideStore();

    await store.setModeOverride('srcA', 'show1', 'rtl');
    await store.setModeOverride('srcB', 'show1', 'vertical');

    expect(store.effectiveMode('srcA', 'show1', prefs), 'rtl');
    expect(store.effectiveMode('srcB', 'show1', prefs), 'vertical');
    // Same showId under a different sourceId never leaked in.
    expect(store.modeOverride('srcA', 'show2'), isNull);
  });

  test(
    'mode and fit are independent fields — setting one leaves the other clear',
    () async {
      final store = ReaderOverrideStore();
      await store.setFitOverride('src', 'show', 'width');

      expect(store.modeOverride('src', 'show'), isNull);
      expect(store.fitOverride('src', 'show'), 'width');
    },
  );
}
