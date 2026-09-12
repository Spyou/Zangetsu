import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  group('rateToRestoreAfterHold', () {
    test('gives back the speed the viewer had chosen', () {
      // The reported bug: pick 2x, hold, let go — and you were at 1x.
      expect(rateToRestoreAfterHold(2.0), 2.0);
      expect(rateToRestoreAfterHold(1.5), 1.5);
      expect(rateToRestoreAfterHold(0.5), 0.5);
    });

    test('normal speed stays normal', () {
      expect(rateToRestoreAfterHold(1.0), 1.0);
    });

    test('a rate of 0 falls back to normal, never back to 0', () {
      // mpv reports 0 while a track is still opening. Restoring it would
      // leave the video stopped with no obvious way back.
      expect(rateToRestoreAfterHold(0), 1.0);
      expect(rateToRestoreAfterHold(-1), 1.0);
    });
  });
}
