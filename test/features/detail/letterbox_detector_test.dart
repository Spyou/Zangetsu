import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/detail/letterbox_detector.dart';

/// A frame [h] rows tall and 64 wide: [bar] black rows at the top and bottom,
/// bright picture in between (or all black when [bright] is false).
Uint8List frame({int h = 100, int bar = 0, bool bright = true}) {
  const w = 64;
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final inBar = y < bar || y >= h - bar;
    final v = (bright && !inBar) ? 200 : 0;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      px[i] = v;
      px[i + 1] = v;
      px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return px;
}

void main() {
  group('detectBar', () {
    test('finds bars at the top and bottom, with a little padding', () {
      final bar = LetterboxDetector.detectBar(frame(bar: 12), 64, 100)!;
      expect(bar, closeTo(0.13, 0.001));
    });

    test('no bars reads as zero', () {
      expect(LetterboxDetector.detectBar(frame(), 64, 100), 0);
    });

    test('a tiny bar is ignored', () {
      expect(LetterboxDetector.detectBar(frame(bar: 2), 64, 100), 0);
    });

    test('an all-dark frame says nothing', () {
      expect(
        LetterboxDetector.detectBar(frame(bright: false), 64, 100),
        isNull,
      );
    });

    test(
      'bars taller than a fifth are not trusted (probably a dark scene)',
      () {
        expect(LetterboxDetector.detectBar(frame(bar: 30), 64, 100), isNull);
      },
    );

    test('uses the smaller of the two bars', () {
      final px = frame(bar: 0);
      // Blacken 15 rows at the top only.
      for (var i = 0; i < 15 * 64 * 4; i += 4) {
        px[i] = 0;
        px[i + 1] = 0;
        px[i + 2] = 0;
      }
      expect(LetterboxDetector.detectBar(px, 64, 100), 0);
    });

    test('rejects a buffer that is too small', () {
      expect(LetterboxDetector.detectBar(Uint8List(10), 64, 100), isNull);
    });
  });

  group('zoomFor', () {
    test('1 when there is nothing to remove', () {
      expect(LetterboxDetector.zoomFor(0), 1);
    });

    test('grows with the bar', () {
      expect(LetterboxDetector.zoomFor(0.13), closeTo(1.351, 0.001));
    });
  });

  group('sample window', () {
    test('open for the first fifth of the trailer', () {
      expect(LetterboxDetector.isSampleWindowOver(10000, 100000), isFalse);
      expect(LetterboxDetector.isSampleWindowOver(20000, 100000), isTrue);
    });

    test('never over while the length is unknown', () {
      expect(LetterboxDetector.isSampleWindowOver(5000, 0), isFalse);
    });
  });

  group('LetterboxTracker', () {
    test('waits for four agreeing readings', () {
      final t = LetterboxTracker();
      expect(t.onSample(0.13), isNull);
      expect(t.onSample(0.13), isNull);
      expect(t.onSample(0.14), isNull);
      expect(t.onSample(0.13), closeTo(1.351, 0.01));
    });

    test('a different reading starts the count again', () {
      final t = LetterboxTracker();
      t.onSample(0.13);
      t.onSample(0.13);
      t.onSample(0.13);
      expect(t.onSample(0.05), isNull);
    });

    test('stable "no bars" never zooms', () {
      final t = LetterboxTracker();
      for (var i = 0; i < 6; i++) {
        expect(t.onSample(0), isNull);
      }
    });
  });
}
