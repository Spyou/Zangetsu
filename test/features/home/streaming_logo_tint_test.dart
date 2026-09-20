import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/home/streaming_logo_tint.dart';

/// Build a width x height RGBA buffer, painting each row with `colourAt`.
Uint8List _img(int w, int h, Color Function(int x, int y) colourAt) {
  final b = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = colourAt(x, y);
      final o = (y * w + x) * 4;
      b[o] = (c.r * 255).round();
      b[o + 1] = (c.g * 255).round();
      b[o + 2] = (c.b * 255).round();
      b[o + 3] = (c.a * 255).round();
    }
  }
  return b;
}

void main() {
  // Netflix is #000000, Prime Video #FFFFFF, Crunchyroll #FF5E00 — measured off
  // the real TMDB assets. A flat logo must produce a flat card.
  test('a flat background gives the same colour on both sides', () {
    const brand = Color(0xFFFF5E00);
    final t = StreamingLogoTint.sample(
      _img(332, 332, (x, y) => brand),
      332,
      332,
    );
    expect(t, isNotNull);
    expect(t!.start, brand);
    expect(t.end, brand);
    expect(t.isFlat, isTrue);
  });

  // JioHotstar and Zee5 are gradients; a single flat fill seams against them.
  test('a horizontal gradient is read as two different edges', () {
    final t = StreamingLogoTint.sample(
      _img(
        332,
        332,
        (x, y) => Color.lerp(
          const Color(0xFF00A8FF),
          const Color(0xFF0033AA),
          x / 331,
        )!,
      ),
      332,
      332,
    );
    expect(t, isNotNull);
    expect(t!.isFlat, isFalse);
    expect(t.vertical, isFalse, reason: 'it grades left to right');
    expect(t.start, isNot(t.end));
  });

  // Jolt Film grades top-to-bottom. Reading only the side edges returns the
  // same mid-row colour twice, paints a FLAT card behind a graded logo, and
  // the square's edges show — the box-inside-a-box.
  test('a vertical gradient is detected and reported as vertical', () {
    final t = StreamingLogoTint.sample(
      _img(
        332,
        332,
        (x, y) => Color.lerp(
          const Color(0xFF2B2B2B),
          const Color(0xFF000000),
          y / 331,
        )!,
      ),
      332,
      332,
    );
    expect(t, isNotNull);
    expect(t!.vertical, isTrue);
    expect(t.isFlat, isFalse);
    expect(t.start, isNot(t.end));
  });

  test('a flat logo is not called vertical', () {
    final t = StreamingLogoTint.sample(
      _img(332, 332, (x, y) => const Color(0xFF000000)),
      332,
      332,
    );
    expect(t!.vertical, isFalse);
    expect(t.isFlat, isTrue);
  });

  test('the mark in the middle never decides the colour', () {
    // A bright red blob across the centre, brand black at the edges. Sampling
    // the middle instead of the edges would return red.
    final t = StreamingLogoTint.sample(
      _img(
        332,
        332,
        (x, y) => (x > 80 && x < 250)
            ? const Color(0xFFE50914)
            : const Color(0xFF000000),
      ),
      332,
      332,
    );
    expect(t!.start, const Color(0xFF000000));
    expect(t.end, const Color(0xFF000000));
  });

  // Measured off the live assets: Netflix's N fills 69% of its square, Apple
  // TV's wordmark 61%. Drawn at a fixed size, Apple's card looks emptier than
  // Netflix's even though the cards are identical.
  group('content scale', () {
    StreamingTint scaleFor(double markFraction) {
      const side = 332;
      final mark = (side * markFraction).round();
      final lo = (side - mark) ~/ 2;
      final hi = lo + mark;
      return StreamingLogoTint.sample(
        _img(
          side,
          side,
          (x, y) => (x >= lo && x < hi && y >= lo && y < hi)
              ? const Color(0xFFFFFFFF)
              : const Color(0xFF000000),
        ),
        side,
        side,
      )!;
    }

    test('a small mark is enlarged, a big one is left alone', () {
      final small = scaleFor(0.40).contentScale;
      final big = scaleFor(0.95).contentScale;
      expect(small, greaterThan(big));
      expect(big, 1.0, reason: 'already filling its frame');
    });

    test('a 60% mark lands near the same fill as a 69% one', () {
      final a = scaleFor(0.60);
      final b = scaleFor(0.69);
      expect(0.60 * a.contentScale, closeTo(0.69 * b.contentScale, 0.03));
    });

    test('never shrinks, and never blows a mark up without limit', () {
      expect(scaleFor(0.99).contentScale, 1.0);
      expect(scaleFor(0.05).contentScale, lessThanOrEqualTo(1.35));
    });

    test('a flat logo with no mark at all keeps its natural size', () {
      final t = StreamingLogoTint.sample(
        _img(332, 332, (x, y) => const Color(0xFF000000)),
        332,
        332,
      );
      expect(t!.contentScale, 1.0);
    });
  });

  test('a transparent edge yields no tint — the neutral plate is correct', () {
    final t = StreamingLogoTint.sample(
      _img(332, 332, (x, y) => const Color(0x00000000)),
      332,
      332,
    );
    expect(t, isNull);
  });

  test('an image too small to sample yields no tint rather than throwing', () {
    expect(StreamingLogoTint.sample(_img(4, 4, (x, y) => Colors.red), 4, 4),
        isNull);
    expect(StreamingLogoTint.sample(Uint8List(0), 0, 0), isNull);
  });

  test('a truncated buffer yields no tint rather than reading past the end',
      () {
    expect(StreamingLogoTint.sample(Uint8List(16), 332, 332), isNull);
  });
}
