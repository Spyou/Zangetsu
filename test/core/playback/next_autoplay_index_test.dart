import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/filler_service.dart';

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
}
