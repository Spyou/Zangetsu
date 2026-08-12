import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/reader_settings.dart';

void main() {
  group('readerDecodeWidth', () {
    test('scales device width by zoom headroom', () {
      expect(readerDecodeWidth(1080), 2160); // 2x headroom for pinch-zoom
    });
    test('never returns below device width', () {
      expect(readerDecodeWidth(1080, zoomHeadroom: 0.5), 1080);
    });
    test('caps to a sane maximum so huge webtoon strips do not decode 8k wide', () {
      expect(readerDecodeWidth(4000), 4096);
    });
  });

  group('fitToBoxFit', () {
    test('contain maps to BoxFit.contain', () {
      expect(
        fitToBoxFit(FitMode.contain, pageAspect: 0.7, screenAspect: 0.5),
        BoxFit.contain,
      );
    });
    test('width maps to BoxFit.fitWidth', () {
      expect(
        fitToBoxFit(FitMode.width, pageAspect: 0.7, screenAspect: 0.5),
        BoxFit.fitWidth,
      );
    });
    test('height maps to BoxFit.fitHeight', () {
      expect(
        fitToBoxFit(FitMode.height, pageAspect: 0.7, screenAspect: 0.5),
        BoxFit.fitHeight,
      );
    });
    test('original maps to BoxFit.none', () {
      expect(
        fitToBoxFit(FitMode.original, pageAspect: 0.7, screenAspect: 0.5),
        BoxFit.none,
      );
    });
    test('smart fits width when the page is taller than the screen', () {
      // pageAspect < screenAspect => page is relatively taller/narrower.
      expect(
        fitToBoxFit(FitMode.smart, pageAspect: 0.5, screenAspect: 0.6),
        BoxFit.fitWidth,
      );
    });
    test('smart fits height when the page is not taller than the screen', () {
      expect(
        fitToBoxFit(FitMode.smart, pageAspect: 0.7, screenAspect: 0.6),
        BoxFit.fitHeight,
      );
    });
  });

  group('readerBgColor', () {
    test('black', () {
      expect(readerBgColor('black'), Colors.black);
    });
    test('white', () {
      expect(readerBgColor('white'), Colors.white);
    });
    test('gray', () {
      expect(readerBgColor('gray'), const Color(0xFF121212));
    });
    test('system falls back to the app background', () {
      expect(readerBgColor('system'), isNotNull);
    });
  });
}
