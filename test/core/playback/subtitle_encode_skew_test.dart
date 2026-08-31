import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/subtitle_encode_skew.dart';

void main() {
  test('subtitleSkewFromPackIntros uses intro.end only', () {
    final skew = subtitleSkewFromPackIntros(
      playingIntroEnd: 135,
      vttPackIntroEnd: 122,
      playingOutroStart: 1277,
      vttPackOutroStart: 1265,
    );
    expect(skew, isNotNull);
    expect(skew!.seconds, closeTo(13.0, 0.01));
    expect(skew.afterSeconds, 122);
  });

  test('refineSubtitleSkewWithVttGap aligns on first post-OP cue', () {
    const vtt = 'WEBVTT\n\n'
        '00:00:02.570 --> 00:00:04.000\nA\n\n'
        '00:00:31.300 --> 00:00:33.670\nB\n\n'
        '00:02:05.800 --> 00:02:11.030\nClash!\n\n'
        '00:02:19.400 --> 00:02:21.330\nC\n\n';
    final refined = refineSubtitleSkewWithVttGap(
      vttText: vtt,
      playingIntroEnd: 135,
    );
    expect(refined, isNotNull);
    // 135 - 125.8 = 9.2 (not the 13s intro.end-vs-intro.end overestimate)
    expect(refined!.seconds, closeTo(9.2, 0.01));
    expect(refined.afterSeconds, closeTo(125.800, 0.001));
  });

  test('marker/gap blend lands between the two estimates', () {
    const vtt = 'WEBVTT\n\n'
        '00:00:02.570 --> 00:00:04.000\nA\n\n'
        '00:00:31.300 --> 00:00:33.670\nB\n\n'
        '00:02:05.800 --> 00:02:11.030\nClash!\n\n'
        '00:02:19.400 --> 00:02:21.330\nC\n\n';
    final markers = subtitleSkewFromPackIntros(
      playingIntroEnd: 135,
      vttPackIntroEnd: 122,
    )!;
    final gap = refineSubtitleSkewWithVttGap(
      vttText: vtt,
      playingIntroEnd: 135,
    )!;
    final blended = (markers.seconds + gap.seconds) / 2;
    expect(blended, closeTo(11.1, 0.05));
  });

  test('subtitleSkewFromPackIntros rejects tiny or huge deltas', () {
    expect(
      subtitleSkewFromPackIntros(playingIntroEnd: 36, vttPackIntroEnd: 35),
      isNull,
    );
    expect(
      subtitleSkewFromPackIntros(playingIntroEnd: 200, vttPackIntroEnd: 35),
      isNull,
    );
  });

  test('vttOpeningGapSeconds finds anime OP silence', () {
    const vtt = 'WEBVTT\n\n'
        '00:00:02.570 --> 00:00:04.000\nA\n\n'
        '00:00:31.300 --> 00:00:33.670\nB\n\n'
        '00:02:05.800 --> 00:02:11.030\nClash!\n\n'
        '00:02:19.400 --> 00:02:21.330\nC\n\n';
    final gap = vttOpeningGapSeconds(vtt);
    expect(gap, isNotNull);
    expect(gap!.beforeEnd, closeTo(33.670, 0.001));
    expect(gap.afterStart, closeTo(125.800, 0.001));
  });

  test('applySubtitleSkewToText shifts only post-OP cues', () {
    const vtt = 'WEBVTT\n\n'
        '00:00:02.570 --> 00:00:04.000\nPre\n\n'
        '00:02:05.800 --> 00:02:11.030\nPost\n\n';
    final out = applySubtitleSkewToText(
      vtt,
      skewSeconds: 9.2,
      afterSeconds: 125.8,
    );
    expect(out, contains('00:00:02.570 --> 00:00:04.000'));
    expect(out, contains('00:02:15.000 --> 00:02:20.230'));
  });
}
