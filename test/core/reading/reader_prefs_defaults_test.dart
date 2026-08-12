import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reader_prefs_defaults');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group("new pref defaults (fresh box == today's behavior)", () {
    test('manga defaults', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      expect(p.readingMode, 'ltr'); // matches the default legacy direction
      expect(p.fitMode, 'contain');
      expect(p.mangaBackground, 'black'); // matches the default legacy value
      expect(p.doublePageLandscape, isFalse);
      expect(p.cropBorders, isFalse);
      expect(p.webtoonPageGap, 0);
      expect(p.colorFilter, 'none');
    });

    test('shared comfort defaults', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      expect(p.brightness, -1); // system/off — reader has never touched this
      expect(p.orientation, 'system'); // no lock — today's behavior
      expect(p.keepScreenOn, isTrue); // pre-existing, unaffected
    });

    test('novel defaults', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      expect(p.fontFamily, 'inter');
      expect(p.textAlignJustify, isFalse);
      expect(p.paragraphSpacing, 8);
      expect(p.novelPaginated, isFalse);
    });
  });

  group('migrate-on-read from legacy keys', () {
    test('readingMode derives from direction until explicitly set', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();

      await p.setDirection('ltr');
      expect(p.readingMode, 'ltr');
      await p.setDirection('rtl');
      expect(p.readingMode, 'rtl');
      await p.setDirection('vertical');
      expect(p.readingMode, 'webtoon');

      // Once readingMode is explicitly written, it wins over direction.
      await p.setReadingMode('webtoon');
      await p.setDirection('ltr');
      expect(p.readingMode, 'webtoon');
    });

    test(
      'mangaBackground derives from background until explicitly set',
      () async {
        await ReaderPrefs.init();
        final p = ReaderPrefs();

        await p.setBackground('black');
        expect(p.mangaBackground, 'black');
        await p.setBackground('dark');
        expect(p.mangaBackground, 'system');

        // Once mangaBackground is explicitly written, it wins over background.
        await p.setMangaBackground('gray');
        await p.setBackground('black');
        expect(p.mangaBackground, 'gray');
      },
    );

    test('legacy direction/background getters keep working untouched', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      await p.setDirection('rtl');
      await p.setBackground('dark');
      expect(p.direction, 'rtl');
      expect(p.background, 'dark');
    });
  });
}
