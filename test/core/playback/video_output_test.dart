import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

/// The exact expression `resolveVideoOutput` replaced in PlayerController.
/// Kept here so the "auto changes nothing" claim is checked against the old
/// code rather than against a restatement of the new code.
String? legacyVideoOutput({required bool isTv, required String shaderStyle}) =>
    (!isTv && shaderStyle != 'off') ? 'gpu-next' : null;

void main() {
  const shaderStyles = ['off', 'a', 'b', 'c'];

  group('auto is byte-identical to the old hardcoded behaviour', () {
    test('every isTv x shaderStyle combination matches the old expression', () {
      for (final isTv in [true, false]) {
        for (final style in shaderStyles) {
          expect(
            resolveVideoOutput(isTv: isTv, choice: 'auto', shaderStyle: style),
            legacyVideoOutput(isTv: isTv, shaderStyle: style),
            reason: 'auto diverged for isTv=$isTv shaderStyle=$style',
          );
        }
      }
    });

    test('spelled out: Anime4K off → null, on → gpu-next', () {
      expect(
        resolveVideoOutput(isTv: false, choice: 'auto', shaderStyle: 'off'),
        isNull,
      );
      expect(
        resolveVideoOutput(isTv: false, choice: 'auto', shaderStyle: 'a'),
        'gpu-next',
      );
    });
  });

  group('explicit choices', () {
    test('are passed through to mpv', () {
      for (final vo in ['gpu', 'gpu-next', 'mediacodec_embed']) {
        expect(
          resolveVideoOutput(isTv: false, choice: vo, shaderStyle: 'off'),
          vo,
        );
      }
    });

    test('override Anime4K rather than being overridden by it', () {
      // Picking a renderer explicitly must win — otherwise someone escaping a
      // black screen with mediacodec_embed would be silently put back on
      // gpu-next just because Anime4K happened to be on.
      expect(
        resolveVideoOutput(
          isTv: false,
          choice: 'mediacodec_embed',
          shaderStyle: 'a',
        ),
        'mediacodec_embed',
      );
    });
  });

  group('TV', () {
    test('never gets an mpv renderer, whatever is picked', () {
      for (final vo in ['auto', 'gpu', 'gpu-next', 'mediacodec_embed']) {
        for (final style in shaderStyles) {
          expect(
            resolveVideoOutput(isTv: true, choice: vo, shaderStyle: style),
            isNull,
            reason: 'TV leaked a renderer for choice=$vo style=$style',
          );
        }
      }
    });
  });
}
