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
}
