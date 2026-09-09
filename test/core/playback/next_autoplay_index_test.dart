import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/filler_service.dart';

Episode _unaired(int n) => Episode(
      id: 'e$n',
      title: 'Episode $n',
      number: n.toDouble(),
      url: 'https://example.com/$n',
      unavailable: 'Not out yet',
    );

Episode _ep(int n) => Episode(
      id: 'e$n',
      title: 'Episode $n',
      number: n.toDouble(),
      url: 'https://example.com/$n',
    );

void main() {
  final eps = [_ep(1), _ep(2), _ep(3), _ep(4), _ep(5)];

  group('nextAutoplayIndex', () {
    test('returns null at end of list', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 4,
          episodes: eps,
          fillerEps: {2, 3},
          autoSkipFiller: true,
        ),
        isNull,
      );
    });

    test('returns immediate next when auto-skip is off', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 0,
          episodes: eps,
          fillerEps: {2, 3},
          autoSkipFiller: false,
        ),
        1,
      );
    });

    test('returns immediate next when filler set is empty', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 0,
          episodes: eps,
          fillerEps: const {},
          autoSkipFiller: true,
        ),
        1,
      );
    });

    test('skips consecutive fillers', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 0,
          episodes: eps,
          fillerEps: {2, 3},
          autoSkipFiller: true,
        ),
        3, // index of ep 4
      );
    });

    test('falls back to immediate next when rest of list is filler', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 0,
          episodes: eps,
          fillerEps: {2, 3, 4, 5},
          autoSkipFiller: true,
        ),
        1,
      );
    });

    test('does not skip a non-filler immediate next', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 0,
          episodes: eps,
          fillerEps: {3, 4},
          autoSkipFiller: true,
        ),
        1,
      );
    });
  });

  group('an episode nothing has yet is not a next episode', () {
    // The player used to offer Next into an episode the catalogue listed but
    // that had not aired — a button that could only fail, and autoplay rolling
    // into a dead end at the end of every airing season.
    final airing = [_ep(1), _ep(2), _unaired(3)];

    test('no Next into an unaired episode', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 1,
          episodes: airing,
          fillerEps: const {},
          autoSkipFiller: false,
        ),
        isNull,
      );
    });

    test('Next still works while the following one is playable', () {
      expect(
        nextAutoplayIndex(
          currentIndex: 0,
          episodes: airing,
          fillerEps: const {},
          autoSkipFiller: false,
        ),
        1,
      );
    });

    test('skipping filler never lands on an unaired episode', () {
      // 2 is filler, 3 has not aired: skipping 2 must not jump to 3.
      expect(
        nextAutoplayIndex(
          currentIndex: 0,
          episodes: airing,
          fillerEps: const {2},
          autoSkipFiller: true,
        ),
        1,
        reason: 'falls back to the immediate one rather than a dead end',
      );
    });
  });
}
