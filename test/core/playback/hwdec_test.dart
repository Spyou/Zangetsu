import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

/// The EXACT expression `resolveHwdec` replaced, which named Android's decoder
/// on every platform. Kept here so "Android is unchanged" is checked against
/// the old code rather than against a restatement of the new code.
String legacyHwdec({required String choice, required String videoOutput}) {
  if (videoOutput == 'mediacodec_embed') return 'mediacodec';
  switch (choice) {
    case 'direct':
      return 'mediacodec';
    case 'sw':
      return 'no';
    case 'auto':
      return 'auto-safe';
    case 'copy':
    default:
      return 'mediacodec-copy';
  }
}

/// Every stored value `videoDecoder` can return, including a junk one to prove
/// the default arm still behaves.
const choices = ['copy', 'direct', 'sw', 'auto', 'something-unknown'];
const outputs = ['auto', 'gpu', 'gpu-next', 'mediacodec_embed'];

void main() {
  group('Android is byte-identical to before', () {
    test('every choice x videoOutput matches the old expression', () {
      for (final c in choices) {
        for (final o in outputs) {
          expect(
            resolveHwdec(
              choice: c,
              videoOutput: o,
              platform: DecoderPlatform.android,
            ),
            legacyHwdec(choice: c, videoOutput: o),
            reason: 'Android diverged for choice=$c videoOutput=$o',
          );
        }
      }
    });

    test('mediacodec_embed still wins over the decoder pick', () {
      expect(
        resolveHwdec(
          choice: 'sw',
          videoOutput: 'mediacodec_embed',
          platform: DecoderPlatform.android,
        ),
        'mediacodec',
        reason: 'the renderer override must still come first',
      );
    });
  });

  group('Apple gets its own decoder, never Android name', () {
    test('the default mode takes the copy path, which always hw-decodes', () {
      // Measured on a real iOS build: plain videotoolbox needs mpv's GL
      // interop, and without it mpv logs "Using software decoding" — the exact
      // failure this whole mapping exists to prevent. videotoolbox-copy logs
      // "Trying hardware decoding" instead, so the DEFAULT must be the copy.
      expect(
        resolveHwdec(
          choice: 'copy',
          videoOutput: 'auto',
          platform: DecoderPlatform.apple,
        ),
        'videotoolbox-copy',
      );
    });

    test('the explicit no-readback mode is the non-copy decoder', () {
      expect(
        resolveHwdec(
          choice: 'direct',
          videoOutput: 'auto',
          platform: DecoderPlatform.apple,
        ),
        'videotoolbox',
      );
    });

    test('software and auto are platform-neutral, so they are unchanged', () {
      expect(
        resolveHwdec(
          choice: 'sw',
          videoOutput: 'auto',
          platform: DecoderPlatform.apple,
        ),
        'no',
      );
      expect(
        resolveHwdec(
          choice: 'auto',
          videoOutput: 'auto',
          platform: DecoderPlatform.apple,
        ),
        'auto-safe',
      );
    });

    test('the Android-only renderer cannot leak a mediacodec name onto Apple', () {
      // The Video renderer setting is not platform-gated in the UI, so a stored
      // 'mediacodec_embed' must not resurrect Android's decoder here.
      expect(
        resolveHwdec(
          choice: 'copy',
          videoOutput: 'mediacodec_embed',
          platform: DecoderPlatform.apple,
        ),
        'videotoolbox-copy',
      );
    });
  });

  group('no platform is ever handed another platform decoder', () {
    const forbidden = {
      DecoderPlatform.android: ['videotoolbox', 'd3d11va', 'vaapi'],
      DecoderPlatform.apple: ['mediacodec', 'd3d11va', 'vaapi'],
      DecoderPlatform.windows: ['mediacodec', 'videotoolbox', 'vaapi'],
      DecoderPlatform.linux: ['mediacodec', 'videotoolbox', 'd3d11va'],
      DecoderPlatform.other: ['mediacodec', 'videotoolbox', 'd3d11va', 'vaapi'],
    };

    test('across every platform x choice x videoOutput', () {
      for (final entry in forbidden.entries) {
        for (final c in choices) {
          for (final o in outputs) {
            final got = resolveHwdec(
              choice: c,
              videoOutput: o,
              platform: entry.key,
            );
            for (final bad in entry.value) {
              expect(
                got.contains(bad),
                isFalse,
                reason:
                    '${entry.key.name} got "$got" (contains "$bad") '
                    'for choice=$c videoOutput=$o',
              );
            }
          }
        }
      }
    });

    test('every platform returns a non-empty value for every choice', () {
      for (final p in DecoderPlatform.values) {
        for (final c in choices) {
          expect(
            resolveHwdec(choice: c, videoOutput: 'auto', platform: p),
            isNotEmpty,
            reason: '${p.name} returned nothing for choice=$c',
          );
        }
      }
    });
  });
}
