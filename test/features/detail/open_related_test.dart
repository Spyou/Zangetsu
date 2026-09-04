// A relation tapped from a manga page is often an ANIME (the adaptation), and
// the reverse from an anime page. The old code searched whichever source the
// page came from, so those taps could only ever answer "not on this source" —
// the exact links people most want to follow. What the relation IS decides
// where it opens, and MAL's manga and anime ids are separate sequences, so the
// kind is what makes the number mean anything.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/open_related.dart';

void main() {
  test('a manga id resolves against the manga catalogue', () {
    final c = canonicalForRelated(isReading: true, malId: 25);

    expect(c!.kind, ZKind.manga);
    expect(c.id, 'mal:25');
  });

  test('the same number as an anime is a different title', () {
    final manga = canonicalForRelated(isReading: true, malId: 25)!;
    final anime = canonicalForRelated(isReading: false, malId: 25)!;

    // MAL manga 25 is Fullmetal Alchemist; MAL anime 25 is Sunabouzu. Same
    // number, unrelated shows — which is why reading the flag matters.
    expect(manga.kind, isNot(anime.kind));
    expect(manga, isNot(anime));
  });

  test('a TMDB series and a film are told apart', () {
    expect(
      canonicalForRelated(isReading: false, tmdbId: 1396, tmdbIsTv: true)!.kind,
      ZKind.tv,
    );
    expect(
      canonicalForRelated(isReading: false, tmdbId: 27205)!.kind,
      ZKind.movie,
    );
  });

  test('MAL wins over TMDB when a relation carries both', () {
    final c = canonicalForRelated(isReading: false, malId: 5114, tmdbId: 31911);

    expect(c!.id, 'mal:5114');
  });

  test('a relation with no id at all has no metadata page to open', () {
    // Source-supplied relations (CloudStream recommendations) carry no ids;
    // those still have to go through a title search on the current source.
    expect(canonicalForRelated(isReading: false), isNull);
  });

  group('AniList entries with no MAL id', () {
    test('fall back to AniList own id instead of having no identity', () {
      // Korean and Chinese titles routinely carry no MAL id. Without this a
      // relation had nothing to open, so the tap could only search the source
      // and dead-end on "not on this source".
      final c = canonicalForRelated(isReading: false, anilistId: 12345)!;
      expect(c.id, 'al:12345');
      expect(c.kind, ZKind.anime);
    });

    test('a MAL id still wins — most of the catalogue is keyed by it', () {
      final c = canonicalForRelated(
        isReading: false,
        malId: 21,
        anilistId: 999,
      )!;
      expect(c.id, 'mal:21');
    });

    test('the reading flag still decides the kind', () {
      expect(
        canonicalForRelated(isReading: true, anilistId: 7)!.kind,
        ZKind.manga,
      );
    });

    test('TMDB wins over an AniList id', () {
      final c = canonicalForRelated(
        isReading: false,
        anilistId: 7,
        tmdbId: 42,
        tmdbIsTv: true,
      )!;
      expect(c.id, 'tmdb:42');
    });

    test('no id at all is still null, so the toast path survives', () {
      expect(canonicalForRelated(isReading: false), isNull);
    });
  });
}
