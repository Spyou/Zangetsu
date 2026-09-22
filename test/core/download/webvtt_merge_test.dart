import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/webvtt_merge.dart';
import 'package:watch_app/core/playback/hls.dart';

/// A downloaded episode came back with no subtitles even when the stream had
/// them: nothing read `#EXT-X-MEDIA:TYPE=SUBTITLES`, and MediaMuxer cannot
/// carry a subtitle track in an MP4 anyway. These pin the two pieces that
/// replace it — finding the rendition, and joining its segments into one file.
void main() {
  group('parseHlsSubtitles', () {
    const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",URI="a/en.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="s/en.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Arabic",LANGUAGE="ar",DEFAULT=NO,URI="https://cdn.test/s/ar.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,SUBTITLES="subs"
v/720.m3u8
''';

    test('finds every subtitle rendition and resolves relative urls', () {
      final subs = parseHlsSubtitles(master, 'https://cdn.test/x/master.m3u8');

      expect(subs, hasLength(2));
      expect(subs[0].url, 'https://cdn.test/x/s/en.m3u8');
      expect(subs[0].lang, 'en');
      expect(subs[0].label, 'English');
      expect(subs[0].isDefault, isTrue);
      expect(subs[1].url, 'https://cdn.test/s/ar.m3u8', reason: 'absolute');
      expect(subs[1].isDefault, isFalse);
    });

    test('ignores audio renditions and video variants', () {
      final subs = parseHlsSubtitles(master, 'https://cdn.test/x/master.m3u8');
      expect(subs.map((s) => s.lang), ['en', 'ar']);
    });

    test('a media playlist has none', () {
      expect(
        parseHlsSubtitles('#EXTM3U\n#EXTINF:6,\na.ts\n', 'https://x/m.m3u8'),
        isEmpty,
      );
    });

    test('a rendition with no URI is skipped, not half-reported', () {
      const noUri =
          '#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="Broken",LANGUAGE="fr"\n';
      expect(parseHlsSubtitles(noUri, 'https://x/m.m3u8'), isEmpty);
    });

    test('falls back to the language when a rendition has no name', () {
      const noName =
          '#EXT-X-MEDIA:TYPE=SUBTITLES,LANGUAGE="es",URI="s/es.m3u8"\n';
      final subs = parseHlsSubtitles(noName, 'https://x/m.m3u8');
      expect(subs.single.label, 'es');
    });
  });

  group('mergeWebVtt', () {
    test('keeps one header, not one per segment', () {
      final out = mergeWebVtt(const [
        VttSegment(
          text: 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n',
          startSeconds: 0,
        ),
        VttSegment(
          text: 'WEBVTT\n\n00:00:11.000 --> 00:00:12.000\nWorld\n',
          startSeconds: 10,
        ),
      ]);

      expect('WEBVTT'.allMatches(out).length, 1, reason: 'a second header ends playback');
      expect(out, contains('Hello'));
      expect(out, contains('World'));
    });

    test('media-timeline cues are left exactly where they were', () {
      final out = mergeWebVtt(const [
        VttSegment(
          text: 'WEBVTT\n\n00:00:11.000 --> 00:00:12.500\nLate line\n',
          startSeconds: 10,
        ),
      ]);

      expect(out, contains('00:00:11.000 --> 00:00:12.500'));
    });

    test('segment-relative cues are shifted onto the media timeline', () {
      // Cues starting at 0 in a segment that begins at 10s can only be
      // relative — left alone they would all pile up at the start.
      final out = mergeWebVtt(const [
        VttSegment(
          text: 'WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nShift me\n',
          startSeconds: 10,
        ),
      ]);

      expect(out, contains('00:00:10.000 --> 00:00:11.500'));
    });

    test('drops the per-segment timing map', () {
      final out = mergeWebVtt(const [
        VttSegment(
          text: 'WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n'
              '00:00:01.000 --> 00:00:02.000\nHi\n',
          startSeconds: 0,
        ),
      ]);

      expect(out, isNot(contains('X-TIMESTAMP-MAP')));
      expect(out, contains('Hi'));
    });

    test('keeps cue settings and multi-line text', () {
      final out = mergeWebVtt(const [
        VttSegment(
          text: 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000 align:start position:10%\n'
              'first line\nsecond line\n',
          startSeconds: 0,
        ),
      ]);

      expect(out, contains('align:start position:10%'));
      expect(out, contains('first line'));
      expect(out, contains('second line'));
    });

    test('handles MM:SS.mmm timestamps', () {
      final out = mergeWebVtt(const [
        VttSegment(text: 'WEBVTT\n\n01:02.500 --> 01:04.000\nShort form\n', startSeconds: 0),
      ]);

      expect(out, contains('00:01:02.500 --> 00:01:04.000'));
    });

    test('no segments is an empty but valid file', () {
      expect(mergeWebVtt(const []).trim(), 'WEBVTT');
    });

    test('a malformed cue is dropped rather than poisoning the file', () {
      final out = mergeWebVtt(const [
        VttSegment(
          text: 'WEBVTT\n\nnot:a:time --> nope\nignored\n\n'
              '00:00:05.000 --> 00:00:06.000\nkept\n',
          startSeconds: 0,
        ),
      ]);

      expect(out, contains('kept'));
      expect(out, isNot(contains('nope')));
    });
  });

  test('parseVttTimestamp reads both forms', () {
    expect(parseVttTimestamp('00:00:01.500'), 1.5);
    expect(parseVttTimestamp('01:02.250'), 62.25);
    expect(parseVttTimestamp('1:00:00.000'), 3600);
    expect(parseVttTimestamp('garbage'), isNull);
  });
}
