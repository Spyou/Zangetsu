import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  group('audio/subs sheet focus', () {
    test('no focus shows both columns (fullscreen unchanged)', () {
      expect(audioSubsColumns(null), (audio: true, subtitles: true));
    });

    test('audio focus shows only the audio column', () {
      expect(
        audioSubsColumns(AudioSubsFocus.audio),
        (audio: true, subtitles: false),
      );
    });

    test('subtitles focus shows only the subtitle column', () {
      expect(
        audioSubsColumns(AudioSubsFocus.subtitles),
        (audio: false, subtitles: true),
      );
    });
  });
}
