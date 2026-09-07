// The outline preset used to reach only the Flutter overlay. mpv was sent one
// hardcoded border size, so with styled subtitles (libass) on, glow, bold,
// drop shadow and the rest all drew the same thin edge — the preview promised
// a look the video never delivered.
//
// These pin the libass numbers per preset. What matters is not the exact
// values but that the six presets stay DIFFERENT from each other, and that
// glow is the one that blurs.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/subtitle_style.dart';

void main() {
  const w = 2.0;

  test('glow is a border WITH blur — that is what makes it a glow', () {
    final o = libassOutline('glow', w);
    expect(o.blur, greaterThan(0));
    expect(o.border, greaterThan(0));
  });

  test('outline and bold are hard edges, no blur', () {
    expect(libassOutline('outline', w).blur, 0);
    expect(libassOutline('bold', w).blur, 0);
    // Bold is the thicker of the two, or the two presets are the same thing.
    expect(
      libassOutline('bold', w).border,
      greaterThan(libassOutline('outline', w).border),
    );
  });

  test('drop shadow is the only preset that offsets', () {
    expect(libassOutline('shadow', w).shadow, greaterThan(0));
    for (final t in ['none', 'outline', 'bold', 'glow', 'soft']) {
      expect(libassOutline(t, w).shadow, 0, reason: t);
    }
  });

  test('none draws nothing at all', () {
    final o = libassOutline('none', w);
    expect(o.border, 0);
    expect(o.blur, 0);
    expect(o.shadow, 0);
  });

  test('soft is a blurred halo, and is what an unknown id falls back to', () {
    final soft = libassOutline('soft', w);
    expect(soft.blur, greaterThan(0));
    expect(libassOutline('something-new', w), soft);
  });

  test('every preset is visually distinct from every other', () {
    // The bug in one assertion: six presets that all produce the same numbers
    // are six presets the user cannot tell apart.
    const ids = ['none', 'soft', 'outline', 'bold', 'shadow', 'glow'];
    final seen = <({double border, double blur, double shadow})>{};
    for (final id in ids) {
      expect(seen.add(libassOutline(id, w)), isTrue, reason: '$id collides');
    }
  });

  test('thickness scales with the width setting', () {
    expect(
      libassOutline('outline', 4).border,
      greaterThan(libassOutline('outline', 1).border),
    );
  });

  test('a zero width still leaves glow and soft visible', () {
    // Width 0 means "no outline" for the hard presets, but a glow with no blur
    // would just be invisible text styling with nothing to show for it.
    expect(libassOutline('glow', 0).blur, greaterThan(0));
    expect(libassOutline('soft', 0).blur, greaterThan(0));
  });
}
