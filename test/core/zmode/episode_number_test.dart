import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/zmode/episode_number.dart';

// Asking a source for "episode 5" by taking its 5th entry breaks the moment it
// slips a recap into the list — every episode after shifts, and the tracker is
// told the wrong number too. These pin the number-first lookup and, just as
// importantly, that it falls back to position wherever it cannot do better.

Episode _ep(String title, {double? number, String url = 'u'}) =>
    Episode(id: title, title: title, number: number, url: url);

void main() {
  group('parseEpisodeNumber', () {
    test('reads the plain forms', () {
      expect(parseEpisodeNumber('Episode 5'), 5);
      expect(parseEpisodeNumber('Ep. 5'), 5);
      expect(parseEpisodeNumber('EP5'), 5);
      expect(parseEpisodeNumber('E5'), 5);
    });

    test('keeps recap and special decimals', () {
      // The whole point: 5.5 must not become 6 and take a real slot.
      expect(parseEpisodeNumber('Episode 5.5 - Recap'), 5.5);
    });

    test('ignores resolutions, versions and season markers', () {
      // Each of these is a number that would otherwise win.
      expect(parseEpisodeNumber('Ep. 5 [1080p]'), 5);
      expect(parseEpisodeNumber('Bleach - 5 (v2)'), 5);
      expect(parseEpisodeNumber('S2 - Episode 3'), 3);
      expect(parseEpisodeNumber('Season 2 Episode 3'), 3);
      expect(parseEpisodeNumber('[Hi10] Episode 7'), 7);
    });

    test('falls back to a bare number when nothing is marked', () {
      expect(parseEpisodeNumber('Bleach 12'), 12);
    });

    test('says nothing rather than guessing', () {
      expect(parseEpisodeNumber('Movie'), isNull);
      expect(parseEpisodeNumber('Special'), isNull);
      expect(parseEpisodeNumber(''), isNull);
      // A resolution alone is not an episode number.
      expect(parseEpisodeNumber('[1080p]'), isNull);
    });
  });

  group('sourceEpisodeNumber', () {
    test('a stated number beats one parsed from the title', () {
      // CloudStream reports real numbers; never second-guess them.
      expect(sourceEpisodeNumber(_ep('Episode 9', number: 4)), 4);
    });

    test('falls back to the title when the field is missing or junk', () {
      expect(sourceEpisodeNumber(_ep('Episode 9')), 9);
      expect(sourceEpisodeNumber(_ep('Episode 9', number: 0)), 9);
    });
  });

  group('episodeNumbersAreReliable', () {
    test('a rising run is trustworthy', () {
      expect(episodeNumbersAreReliable([1, 2, 3]), isTrue);
      expect(episodeNumbersAreReliable([1, 1.5, 2]), isTrue);
    });

    test('a gap is still trustworthy — missing is not ambiguous', () {
      expect(episodeNumbersAreReliable([1, 2, 4]), isTrue);
    });

    test('repeats and restarts are not', () {
      // How a per-season restart looks, and why position is safer there.
      expect(episodeNumbersAreReliable([1, 2, 1, 2]), isFalse);
      expect(episodeNumbersAreReliable([1, 1]), isFalse);
    });

    test('an unnumbered entry poisons the run', () {
      expect(episodeNumbersAreReliable([1, null, 3]), isFalse);
    });
  });

  group('resolveEpisodeIndex', () {
    test('a recap no longer shifts everything after it', () {
      // The bug: position 5 is the recap, not episode 5.
      final eps = [
        _ep('Episode 1'),
        _ep('Episode 2'),
        _ep('Episode 3'),
        _ep('Episode 3.5 - Recap'),
        _ep('Episode 4'),
        _ep('Episode 5'),
      ];
      expect(resolveEpisodeIndex(eps, 5), 5); // the one that SAYS 5
      expect(resolveEpisodeIndex(eps, 4), 4);
      // Position would have given the recap for 4 and episode 4 for 5.
    });

    test('a clean list resolves the same as position did', () {
      final eps = [_ep('Episode 1'), _ep('Episode 2'), _ep('Episode 3')];
      for (var n = 1; n <= 3; n++) {
        expect(resolveEpisodeIndex(eps, n), n - 1);
      }
    });

    test('unreliable numbering falls back to position', () {
      // Two seasons in one list, numbering restarted.
      final eps = [
        _ep('Episode 1'),
        _ep('Episode 2'),
        _ep('Episode 1'),
        _ep('Episode 2'),
      ];
      expect(resolveEpisodeIndex(eps, 3), 2); // position, exactly as today
    });

    test('a number the source does not have falls back to position', () {
      final eps = [_ep('Episode 1'), _ep('Episode 2')];
      expect(resolveEpisodeIndex(eps, 9), 8); // caller range-checks this
    });

    test('untitled, unnumbered episodes still resolve by position', () {
      final eps = [_ep(''), _ep(''), _ep('')];
      expect(resolveEpisodeIndex(eps, 2), 1);
    });
  });
}
