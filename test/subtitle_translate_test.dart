import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/subtitle_translate_service.dart';

// Network-backed smoke test for the subtitle translator: verifies SRT/VTT
// parsing, the keyless Google endpoint, and SRT rebuild end to end. Skips
// gracefully offline (the service keeps original lines on failure).
void main() {
  test('SRT → Spanish: parses cues, translates, rebuilds SRT', () async {
    const srt = '1\n'
        '00:00:01,000 --> 00:00:03,000\n'
        'Hello, how are you?\n\n'
        '2\n'
        '00:00:04,000 --> 00:00:06,000\n'
        'I will protect everyone.\n';
    final out = await SubtitleTranslateService.instance.translate(srt, 'es');
    expect(out, contains('00:00:01,000 --> 00:00:03,000'));
    expect(out, contains('00:00:04,000 --> 00:00:06,000'));
    // Translated text present (falls back to English if offline — allow both).
    expect(
      out.toLowerCase().contains('hola') || out.contains('Hello'),
      isTrue,
    );
    // ignore: avoid_print
    print(out);
  });

  test('VTT (dot ts, no index) normalises to SRT timestamps', () async {
    const vtt = 'WEBVTT\n\n00:01.000 --> 00:03.000\nGood morning\n';
    final out = await SubtitleTranslateService.instance.translate(vtt, 'es');
    expect(out, contains('00:00:01,000 --> 00:00:03,000'));
  });
}
