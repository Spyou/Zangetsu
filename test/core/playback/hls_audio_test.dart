import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/hls.dart';

/// A Netflix-style master: two video renditions plus alternate audio tracks.
/// FFmpeg opens every audio rendition and pulls segments from each before it
/// will show a frame, so we hand mpv a copy carrying only the one we want.
const _master = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="eng",NAME="English",DEFAULT=YES,URI="a/0/0.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="hin",NAME="Hindi",DEFAULT=NO,URI="a/1/1.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="fra",NAME="French",DEFAULT=NO,URI="https://other.cdn/a/2/2.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",LANGUAGE="eng",NAME="English",URI="s/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,AUDIO="aud"
1080p/1080p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=1280x720,AUDIO="aud"
720p/720p.m3u8
''';

const _base = 'https://cdn.example/files/99/master.m3u8';

void main() {
  group('parseHlsAudioRenditions', () {
    test('reads every alternate audio track, resolving relative URIs', () {
      final a = parseHlsAudioRenditions(_master, _base);
      expect(a.map((r) => r.lang), ['eng', 'hin', 'fra']);
      expect(a.map((r) => r.name), ['English', 'Hindi', 'French']);
      expect(a.first.uri, 'https://cdn.example/files/99/a/0/0.m3u8');
      // An already-absolute URI (a different host) is left alone.
      expect(a.last.uri, 'https://other.cdn/a/2/2.m3u8');
      expect(a.first.isDefault, isTrue);
      expect(a[1].isDefault, isFalse);
    });

    test('subtitle renditions are not audio', () {
      final a = parseHlsAudioRenditions(_master, _base);
      expect(a.any((r) => r.uri.contains('/s/')), isFalse);
    });

    test('a media playlist has none, so the caller leaves the url alone', () {
      expect(
        parseHlsAudioRenditions('#EXTM3U\n#EXTINF:4,\nseg0.ts\n', _base),
        isEmpty,
      );
    });
  });

  group('buildTrimmedMaster', () {
    final keep = parseHlsAudioRenditions(_master, _base)[1].uri; // Hindi

    test('keeps only the wanted audio track', () {
      final out = buildTrimmedMaster(_master, _base, keep)!;
      expect(parseHlsAudioRenditions(out, _base).map((r) => r.lang), ['hin']);
    });

    test('keeps both video renditions and makes their URIs absolute', () {
      final out = buildTrimmedMaster(_master, _base, keep)!;
      final v = parseHlsMaster(out, _base);
      expect(v.map((x) => x.quality), ['1080p', '720p']);
      // Absolute, so the copy still resolves when opened from a local file.
      expect(v.every((x) => x.url.startsWith('https://')), isTrue);
      expect(v.first.url, 'https://cdn.example/files/99/1080p/1080p.m3u8');
    });

    test('leaves non-audio lines untouched', () {
      final out = buildTrimmedMaster(_master, _base, keep)!;
      expect(out, contains('#EXT-X-VERSION:3'));
      expect(out, contains('TYPE=SUBTITLES'));
    });

    test('returns null when the wanted track is not in the playlist', () {
      expect(buildTrimmedMaster(_master, _base, 'https://nope/x.m3u8'), isNull);
    });
  });
}
