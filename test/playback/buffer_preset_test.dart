import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  group('buffer presets', () {
    test('default preset returns the legacy hardcoded values (no-break)', () {
      // These MUST match what the player used before this feature existed.
      expect(PlaybackPrefs.bufferMaxBytesFor('default'), '128MiB');
      expect(PlaybackPrefs.bufferMaxBackBytesFor('default'), '48MiB');
      expect(PlaybackPrefs.bufferSecsFor('default'), 60);
    });

    test('unknown/empty preset also falls back to the legacy values', () {
      expect(PlaybackPrefs.bufferMaxBytesFor(''), '128MiB');
      expect(PlaybackPrefs.bufferSecsFor('nonsense'), 60);
    });

    test('low preset shrinks buffers for low-RAM / TV', () {
      expect(PlaybackPrefs.bufferMaxBytesFor('low'), '32MiB');
      expect(PlaybackPrefs.bufferMaxBackBytesFor('low'), '16MiB');
      expect(PlaybackPrefs.bufferSecsFor('low'), 15);
    });

    test('high preset enlarges buffers', () {
      expect(PlaybackPrefs.bufferMaxBytesFor('high'), '512MiB');
      expect(PlaybackPrefs.bufferMaxBackBytesFor('high'), '128MiB');
      expect(PlaybackPrefs.bufferSecsFor('high'), 120);
    });
  });

  group('ExoPlayer buffer presets (TV players + phone DRM)', () {
    test('max buffer mirrors the mpv seconds, so both engines match', () {
      expect(PlaybackPrefs.exoMaxBufferMsFor('low'), 15000);
      expect(PlaybackPrefs.exoMaxBufferMsFor('default'), 60000);
      expect(PlaybackPrefs.exoMaxBufferMsFor('high'), 120000);
      expect(PlaybackPrefs.exoMaxBufferMsFor('nonsense'), 60000);
    });

    test('min buffer never exceeds max — DefaultLoadControl asserts min <= max', () {
      for (final p in ['low', 'default', 'high', '', 'nonsense']) {
        expect(
          PlaybackPrefs.exoMinBufferMsFor(p),
          lessThanOrEqualTo(PlaybackPrefs.exoMaxBufferMsFor(p)),
          reason: 'preset "$p" would crash ExoPlayer at construction',
        );
      }
      // 'low' is 15s, below media3's 50s default, so it has to be clamped down.
      expect(PlaybackPrefs.exoMinBufferMsFor('low'), 15000);
      expect(PlaybackPrefs.exoMinBufferMsFor('high'), 50000);
    });

    test('target bytes mirror the size preset', () {
      expect(PlaybackPrefs.exoTargetBufferBytesFor('low'), 32 * 1024 * 1024);
      expect(PlaybackPrefs.exoTargetBufferBytesFor('default'), 128 * 1024 * 1024);
      expect(PlaybackPrefs.exoTargetBufferBytesFor('high'), 512 * 1024 * 1024);
    });

    test('target bytes stay inside Int range (setTargetBufferBytes takes an int)', () {
      for (final p in ['low', 'default', 'high']) {
        expect(PlaybackPrefs.exoTargetBufferBytesFor(p), lessThan(2147483647));
      }
    });

    test('back buffer is off on low, on otherwise', () {
      expect(PlaybackPrefs.exoBackBufferMsFor('low'), 0);
      expect(PlaybackPrefs.exoBackBufferMsFor('default'), 30000);
      expect(PlaybackPrefs.exoBackBufferMsFor('high'), 30000);
    });

    test('every size × length combination builds a legal LoadControl', () {
      // Size and length are INDEPENDENT settings, so a user can pick e.g.
      // length=low with size=high. DefaultLoadControl asserts
      // bufferForPlayback <= minBuffer <= maxBuffer and would throw at player
      // construction — i.e. no video at all — if any pairing broke that.
      const presets = ['low', 'default', 'high', '', 'nonsense'];
      for (final length in presets) {
        for (final size in presets) {
          final min = PlaybackPrefs.exoMinBufferMsFor(length);
          final max = PlaybackPrefs.exoMaxBufferMsFor(length);
          final bytes = PlaybackPrefs.exoTargetBufferBytesFor(size);
          final back = PlaybackPrefs.exoBackBufferMsFor(size);
          final where = 'length=$length size=$size';
          expect(min, greaterThan(0), reason: where);
          expect(min, lessThanOrEqualTo(max), reason: where);
          // media3's DEFAULT_BUFFER_FOR_PLAYBACK_MS is 2500; Kotlin clamps it
          // to min, so min must stay positive for that clamp to be legal.
          expect(bytes, greaterThan(0), reason: where);
          expect(back, greaterThanOrEqualTo(0), reason: where);
        }
      }
    });
  });
}
