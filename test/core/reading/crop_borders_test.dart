import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/crop_borders.dart';

/// Builds an RGBA buffer [w]x[h] filled with [bg], then paints [content] in.
Uint8List page(
  int w,
  int h,
  List<int> bg, {
  ({int l, int t, int r, int b})? content,
  List<int> ink = const [200, 30, 30],
}) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = bg[0];
    px[i * 4 + 1] = bg[1];
    px[i * 4 + 2] = bg[2];
    px[i * 4 + 3] = 255;
  }
  if (content != null) {
    // Varied, not a flat block: a real page's artwork differs pixel to pixel,
    // and a fixture that is perfectly uniform would make any edge-referenced
    // trim look broken when it is doing exactly the right thing.
    for (var y = content.t; y < content.b; y++) {
      for (var x = content.l; x < content.r; x++) {
        final i = (y * w + x) * 4;
        px[i] = (ink[0] + (x * 7 + y * 13) % 40).clamp(0, 255);
        px[i + 1] = (ink[1] + (x * 3) % 40).clamp(0, 255);
        px[i + 2] = (ink[2] + (y * 5) % 40).clamp(0, 255);
      }
    }
  }
  return px;
}

void main() {
  const black = [0, 0, 0];
  const white = [255, 255, 255];

  group('findContentRect', () {
    // The webtoon case: a slicer pads a slice to a uniform height, so the page
    // arrives with a flat black band that is not artwork.
    test('trims a flat black band at the bottom', () {
      final px = page(64, 100, black, content: (l: 0, t: 0, r: 64, b: 70));
      final rect = findContentRect(px, 64, 100);
      expect(rect.top, 0);
      expect(rect.bottom, 70);
      expect(rect.left, 0);
      expect(rect.right, 64);
    });

    test('trims flat white margins on all four sides', () {
      final px = page(80, 80, white, content: (l: 8, t: 6, r: 72, b: 74));
      final rect = findContentRect(px, 80, 80);
      expect((rect.left, rect.top, rect.right, rect.bottom), (8, 6, 72, 74));
    });

    // The failure that matters: a page that is genuinely a dark panel must not
    // be cropped away. That is why the trim is capped.
    test('a page that is entirely flat is never cropped away', () {
      final px = page(100, 100, black); // a genuinely all-black panel
      final rect = findContentRect(px, 100, 100);
      // The cap is what protects it: at most 40% off any one side, so there
      // is always a page left to look at.
      expect(rect.top, lessThanOrEqualTo(40));
      expect(rect.bottom, greaterThanOrEqualTo(60));
      expect(rect.left, lessThanOrEqualTo(40));
      expect(rect.right, greaterThanOrEqualTo(60));
      expect(rect.bottom - rect.top, greaterThan(0));
      expect(rect.right - rect.left, greaterThan(0));
    });

    test('a page with no margin comes back untouched', () {
      final px = page(40, 40, black, content: (l: 0, t: 0, r: 40, b: 40));
      final rect = findContentRect(px, 40, 40);
      expect((rect.left, rect.top, rect.right, rect.bottom), (0, 0, 40, 40));
    });

    // Scans are never mathematically flat — JPEG leaves a little noise.
    test('tolerates slight noise in a margin', () {
      final px = page(64, 100, black, content: (l: 0, t: 0, r: 64, b: 70));
      for (var y = 80; y < 90; y++) {
        px[(y * 64 + 5) * 4 + 1] = 8; // a few near-black pixels
      }
      expect(findContentRect(px, 64, 100).bottom, 70);
    });

    test('noise beyond the tolerance is treated as content', () {
      final px = page(64, 100, black, content: (l: 0, t: 0, r: 64, b: 70));
      px[(95 * 64 + 5) * 4] = 200; // a bright pixel low down IS artwork
      expect(findContentRect(px, 64, 100).bottom, greaterThan(90));
    });

    test('a malformed buffer is left alone rather than throwing', () {
      expect(findContentRect(Uint8List(4), 100, 100), (
        left: 0,
        top: 0,
        right: 100,
        bottom: 100,
      ));
    });
  });
}
