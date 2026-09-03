import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_title.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';

// One place decides which of AniList's three titles is shown. Before this the
// browse rows took romaji and the library took english, so the same show read
// differently depending on which row you were looking at.

const _full = {
  'romaji': 'Shingeki no Kyojin',
  'english': 'Attack on Titan',
  'native': '進撃の巨人',
};

void main() {
  test('each preference picks its own title', () {
    expect(aniListTitle(_full, TitleLanguage.romaji), 'Shingeki no Kyojin');
    expect(aniListTitle(_full, TitleLanguage.english), 'Attack on Titan');
    expect(aniListTitle(_full, TitleLanguage.native), '進撃の巨人');
  });

  test('a missing preferred title falls back instead of showing nothing', () {
    // AniList leaves english null on plenty of entries.
    const noEnglish = {'romaji': 'Yuru Camp', 'native': 'ゆるキャン△'};
    expect(aniListTitle(noEnglish, TitleLanguage.english), 'Yuru Camp');
    const nativeOnly = {'native': 'ゆるキャン△'};
    expect(aniListTitle(nativeOnly, TitleLanguage.english), 'ゆるキャン△');
  });

  test('empty strings count as missing, not as a title', () {
    const blank = {'romaji': 'Yuru Camp', 'english': ''};
    expect(aniListTitle(blank, TitleLanguage.english), 'Yuru Camp');
  });

  test('a malformed title map yields null rather than throwing', () {
    expect(aniListTitle(null, TitleLanguage.romaji), isNull);
    expect(aniListTitle('nonsense', TitleLanguage.romaji), isNull);
    expect(aniListTitle(const <String, String>{}, TitleLanguage.romaji), isNull);
  });

  group('the alternative kept for source matching', () {
    test('is the variant the display is not', () {
      // Sources index by both romaji and english; dropping one loses matches.
      expect(aniListAltTitle(_full, 'Shingeki no Kyojin'), 'Attack on Titan');
      expect(aniListAltTitle(_full, 'Attack on Titan'), 'Shingeki no Kyojin');
    });

    test('showing native still keeps a latin variant to match on', () {
      expect(aniListAltTitle(_full, '進撃の巨人'), 'Shingeki no Kyojin');
    });

    test('is null when there is no second variant', () {
      const only = {'romaji': 'Yuru Camp'};
      expect(aniListAltTitle(only, 'Yuru Camp'), isNull);
    });
  });
}
