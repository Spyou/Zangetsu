// NSFW used to start off on every search, no matter what Settings said —
// nothing on the Search screen is persisted, so turning 18+ on in Settings
// bought you exactly one thing: the right to tap the chip again, every time.
// These pin the rule that replaced that.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/features/home/search_screen.dart';

void main() {
  group('initialSearchFilters', () {
    test('18+ off in Settings: NSFW starts off', () {
      expect(initialSearchFilters(null, false).adult, isFalse);
    });

    test('18+ on in Settings: NSFW starts on, no second tap needed', () {
      expect(initialSearchFilters(null, true).adult, isTrue);
    });

    test('nothing else is filtered by default', () {
      final f = initialSearchFilters(null, true);
      expect(f.genres, isEmpty);
      expect(f.tags, isEmpty);
      expect(f.year, isNull);
      expect(f.season, isNull);
      expect(f.format, isNull);
      expect(f.status, isNull);
      expect(f.minScore, isNull);
    });

    test('explicit filters win, so a genre tile keeps its own', () {
      // The adult genre tile passes adult:true with Privacy on; an ordinary
      // tile passes adult:false and must NOT be widened by the setting.
      const fromTile = MetaFilters(genres: ['Action']);
      expect(initialSearchFilters(fromTile, true).adult, isFalse);
      expect(initialSearchFilters(fromTile, true).genres, ['Action']);
    });

    test('an explicit adult:true survives even with Privacy read as false', () {
      // The repository is the real gate and strips it there; this function
      // must not second-guess its caller.
      const fromTile = MetaFilters(genres: ['Hentai'], adult: true);
      expect(initialSearchFilters(fromTile, false).adult, isTrue);
    });
  });
}
