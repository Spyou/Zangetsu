import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/brand/zangetsu_mark.dart';

void main() {
  group('parseMarkPath', () {
    test('builds a closed shape from M/L/Z', () {
      final p = ZangetsuMark.parseMarkPath('M0,0 L10,0 L10,10 L0,10 Z');
      expect(p.getBounds(), const Rect.fromLTRB(0, 0, 10, 10));
      expect(p.contains(const Offset(5, 5)), isTrue);
    });

    test('handles several subpaths, which is how the mark is stored', () {
      final p = ZangetsuMark.parseMarkPath(
        'M0,0 L4,0 L4,4 Z M10,10 L14,10 L14,14 Z',
      );
      expect(p.getBounds(), const Rect.fromLTRB(0, 0, 14, 14));
    });

    test(
      'throws on a command it cannot draw, rather than drawing it wrong',
      () {
        // Silently skipping a curve would render a subtly wrong logo, which is
        // far harder to notice than a crash at parse time.
        expect(
          () => ZangetsuMark.parseMarkPath('M0,0 C1,1 2,2 3,3 Z'),
          throwsFormatException,
        );
      },
    );
  });

  group('the mark itself', () {
    test('all three parts parse and are non-empty', () {
      for (final p in [
        ZangetsuMark.crescent,
        ZangetsuMark.blade,
        ZangetsuMark.slash,
      ]) {
        expect(p.getBounds().isEmpty, isFalse);
      }
    });

    test('every part sits inside the box the painter scales from', () {
      const box = Rect.fromLTRB(0, 0, 512, 512);
      for (final entry in {
        'crescent': ZangetsuMark.crescent,
        'blade': ZangetsuMark.blade,
        'slash': ZangetsuMark.slash,
      }.entries) {
        final b = entry.value.getBounds();
        expect(
          box.contains(b.topLeft) && box.contains(b.bottomRight),
          isTrue,
          reason: '${entry.key} escapes the 512 box at $b',
        );
      }
    });

    test('the blade really is the long thin one', () {
      // The splash throws the blade along its own axis and reveals the rest in
      // its wake; if these two were ever swapped the animation would be
      // nonsense, and the shapes are the only thing that says which is which.
      final blade = ZangetsuMark.blade.getBounds();
      final crescent = ZangetsuMark.crescent.getBounds();
      expect(blade.longestSide / blade.shortestSide, greaterThan(1.2));
      expect(blade.longestSide, greaterThan(crescent.longestSide * 0.9));
    });

    test('paths are cached, not reparsed on every frame', () {
      expect(identical(ZangetsuMark.crescent, ZangetsuMark.crescent), isTrue);
      expect(identical(ZangetsuMark.slash, ZangetsuMark.slash), isTrue);
    });
  });
}
