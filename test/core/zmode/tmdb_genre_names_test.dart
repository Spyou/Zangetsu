// TMDB list responses carry `genre_ids`, not genre objects — full `genres`
// only come back on a detail fetch. Nothing mapped them, so every movie/TV
// item reached the app with no genres at all and the genre tiles had nothing
// to match on. These pin the mapping.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';

void main() {
  group('tmdbGenreNames', () {
    test('maps movie ids to names', () {
      expect(
        tmdbGenreNames([28, 35, 27], isTv: false),
        ['Action', 'Comedy', 'Horror'],
      );
    });

    test('uses the TV table for TV, which numbers things differently', () {
      // 10759 is TV's Action/Adventure; on the movie side it means nothing.
      expect(tmdbGenreNames([10759], isTv: true), contains('Action'));
      expect(tmdbGenreNames([10759], isTv: false), isEmpty);
    });

    test('an id shared by two names yields both', () {
      // TV folds Adventure into Action under one id.
      expect(tmdbGenreNames([10759], isTv: true), ['Action', 'Adventure']);
    });

    test('unknown ids are dropped, not guessed', () {
      expect(tmdbGenreNames([999999], isTv: false), isEmpty);
      expect(tmdbGenreNames([28, 999999], isTv: false), ['Action']);
    });

    test('handles the empty and the malformed', () {
      expect(tmdbGenreNames(const [], isTv: false), isEmpty);
      expect(tmdbGenreNames(['not-an-id', null], isTv: false), isEmpty);
    });

    test('string ids still map, since JSON is not always typed', () {
      expect(tmdbGenreNames(['28'], isTv: false), ['Action']);
    });

    test('never repeats a name', () {
      expect(tmdbGenreNames([28, 28], isTv: false), ['Action']);
    });
  });
}
