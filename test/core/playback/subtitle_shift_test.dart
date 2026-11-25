import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/subtitle_shift.dart';

void main() {
  const srt =
      '1\n00:00:01,000 --> 00:00:03,500\nHello\n\n'
      '2\n01:02:03,250 --> 01:02:05,000\nWorld\n';

  test('SRT moves later and keeps the comma and the text', () {
    final out = shiftSubtitle(srt, 1500);
    expect(out, contains('00:00:02,500 --> 00:00:05,000'));
    expect(out, contains('01:02:04,750 --> 01:02:06,500'));
    expect(out, contains('Hello'));
    expect(out, contains('World'));
  });

  test('moving earlier stops at zero and never goes negative', () {
    final out = shiftSubtitle(srt, -2000);
    expect(out, contains('00:00:00,000 --> 00:00:01,500'));
    expect(RegExp(r'(?<!-)-\d').hasMatch(out), isFalse);
  });

  test('WebVTT keeps the dot, cue settings and short timestamps', () {
    const vtt = 'WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nHi\n';
    final out = shiftSubtitle(vtt, 500);
    expect(out, contains('00:00:01.500 --> 00:00:02.500 align:start'));
    expect(out, startsWith('WEBVTT'));
  });

  test('ASS shifts Dialogue lines in centiseconds', () {
    const ass =
        '[Script Info]\n[Events]\nFormat: Layer, Start, End, Style, Text\n'
        'Dialogue: 0,0:00:01.00,0:00:02.50,Default,Hi, there\n';
    final out = shiftSubtitle(ass, 1230);
    expect(
      out,
      contains('Dialogue: 0,0:00:02.23,0:00:03.73,Default,Hi, there'),
    );
  });

  test('a zero shift returns the file untouched', () {
    expect(shiftSubtitle(srt, 0), srt);
  });
}
