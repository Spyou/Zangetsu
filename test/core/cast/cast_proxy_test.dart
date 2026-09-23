import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/cast/cast_proxy.dart';

void main() {
  // Proxify wraps an absolute URL as /p?u=<url> (raw, not encoded — keeps the
  // assertions readable; the real server base64s it).
  String proxify(Uri abs) => '/p?u=$abs';

  final base = Uri.parse('https://cdn.example.com/anime/ep1/index.m3u8');

  test('rewrites relative segment URIs against the playlist base', () {
    const body = '''
#EXTM3U
#EXT-X-VERSION:3
#EXTINF:6.0,
seg0.ts
#EXTINF:6.0,
seg1.ts
#EXT-X-ENDLIST
''';
    final out = rewriteHlsPlaylist(body, base, proxify);
    expect(out, contains('/p?u=https://cdn.example.com/anime/ep1/seg0.ts'));
    expect(out, contains('/p?u=https://cdn.example.com/anime/ep1/seg1.ts'));
    // Tag lines are untouched.
    expect(out, contains('#EXTINF:6.0,'));
    expect(out, contains('#EXT-X-ENDLIST'));
  });

  test('rewrites absolute segment URIs', () {
    const body = '''
#EXTM3U
#EXTINF:6.0,
https://other.cdn.net/a/seg9.ts
''';
    final out = rewriteHlsPlaylist(body, base, proxify);
    expect(out, contains('/p?u=https://other.cdn.net/a/seg9.ts'));
  });

  test('rewrites the URI attribute of EXT-X-KEY and EXT-X-MEDIA', () {
    const body = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/eng.m3u8"
#EXTINF:6.0,
seg0.ts
''';
    final out = rewriteHlsPlaylist(body, base, proxify);
    expect(
      out,
      contains('URI="/p?u=https://cdn.example.com/anime/ep1/key.bin"'),
    );
    expect(
      out,
      contains('URI="/p?u=https://cdn.example.com/anime/ep1/audio/eng.m3u8"'),
    );
    // The METHOD/IV attributes survive.
    expect(out, contains('METHOD=AES-128'));
    expect(out, contains('IV=0x00'));
  });

  test('rewrites variant playlist URIs in a master playlist', () {
    const body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
1080p/index.m3u8
''';
    final out = rewriteHlsPlaylist(body, base, proxify);
    expect(
      out,
      contains('/p?u=https://cdn.example.com/anime/ep1/360p/index.m3u8'),
    );
    expect(
      out,
      contains('/p?u=https://cdn.example.com/anime/ep1/1080p/index.m3u8'),
    );
  });

  test('leaves comment/tag-only playlists structurally intact', () {
    const body = '#EXTM3U\n#EXT-X-VERSION:3\n';
    final out = rewriteHlsPlaylist(body, base, proxify);
    expect(out.contains('/p?u='), isFalse);
    expect(out, contains('#EXTM3U'));
    expect(out, contains('#EXT-X-VERSION:3'));
  });

  group('isPrivateLanIp', () {
    test('accepts RFC-1918 ranges', () {
      expect(isPrivateLanIp('192.168.1.42'), isTrue);
      expect(isPrivateLanIp('10.0.0.5'), isTrue);
      expect(isPrivateLanIp('172.16.0.1'), isTrue);
      expect(isPrivateLanIp('172.31.255.254'), isTrue);
    });
    test('rejects public + out-of-range 172', () {
      expect(isPrivateLanIp('8.8.8.8'), isFalse);
      expect(isPrivateLanIp('172.15.0.1'), isFalse); // below 16
      expect(isPrivateLanIp('172.32.0.1'), isFalse); // above 31
    });
  });

  group('decodePossiblyCompressedUtf8', () {
    const playlist = '#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n';

    test('passes through plain UTF-8', () {
      expect(decodePossiblyCompressedUtf8(utf8.encode(playlist)), playlist);
    });

    test('gunzips a playlist (nexabloom-style Content-Encoding)', () {
      final gz = gzip.encode(utf8.encode(playlist));
      // gzip magic 1f 8b — the byte at offset 1 is what UTF-8 rejected.
      expect(gz[0], 0x1f);
      expect(gz[1], 0x8b);
      expect(decodePossiblyCompressedUtf8(gz), playlist);
      expect(
        decodePossiblyCompressedUtf8(gz, contentEncoding: 'gzip'),
        playlist,
      );
    });
  });

  group('sniffHlsContainer', () {
    test('detects fMP4 from EXT-X-MAP / .m4s', () {
      expect(
        sniffHlsContainer('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\nseg.m4s\n'),
        CastHlsContainer.fmp4,
      );
      expect(
        sniffHlsContainer('#EXTINF:6.0,\nhttps://cdn.example/seg0.m4s\n'),
        CastHlsContainer.fmp4,
      );
    });
    test('detects MPEG-TS from .ts segments', () {
      expect(
        sniffHlsContainer('#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n'),
        CastHlsContainer.ts,
      );
    });
    test('master playlist with no segment hints → null', () {
      expect(
        sniffHlsContainer(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n1080/index.m3u8\n',
        ),
        isNull,
      );
    });
  });

  group('subtitle conversion', () {
    test('looksSubtitleUri matches caption suffixes', () {
      expect(looksSubtitleUri('https://cdn.example/en.vtt'), isTrue);
      expect(looksSubtitleUri('subs.srt?x=1'), isTrue);
      expect(looksSubtitleUri('seg-1.jpg'), isFalse);
    });

    test('srtToWebVtt converts commas and prefixes WEBVTT', () {
      const srt = '''
1
00:00:01,000 --> 00:00:04,000
Hello

2
00:00:05,250 --> 00:00:07,000
World
''';
      final vtt = srtToWebVtt(srt);
      expect(vtt, startsWith('WEBVTT\n\n'));
      expect(vtt, contains('00:00:01.000 --> 00:00:04.000'));
      expect(vtt, contains('00:00:05.250 --> 00:00:07.000'));
      expect(vtt, isNot(contains('00:00:01,000')));
    });

    test('srtToWebVtt leaves WebVTT alone', () {
      const vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n';
      expect(srtToWebVtt(vtt), vtt);
    });

    test('looksLikeSrt distinguishes SubRip from WebVTT', () {
      expect(looksLikeSrt('1\n00:00:01,000 --> 00:00:02,000\nHi\n'), isTrue);
      expect(
        looksLikeSrt('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n'),
        isFalse,
      );
    });
  });

  group('looksDisguisedHlsSegment', () {
    test('treats image/script extensions as decoys', () {
      expect(looksDisguisedHlsSegment('seg-1-f1-v1-a1.jpg'), isTrue);
      expect(
        looksDisguisedHlsSegment('https://cdn.example/a/seg.jpg?x=1'),
        isTrue,
      );
      expect(looksDisguisedHlsSegment('chunk.js'), isTrue);
      expect(looksDisguisedHlsSegment('seg-26-f1-v1-a1.ico'), isTrue);
      expect(looksDisguisedHlsSegment('seg001.ts'), isFalse);
      expect(looksDisguisedHlsSegment('init.mp4'), isFalse);
    });
  });

  group('hlsVariantCount / castProxyEncodedPayload', () {
    test('counts STREAM-INF lines', () {
      expect(hlsVariantCount('#EXTM3U\n#EXTINF:6.0,\nseg.ts\n'), 0);
      expect(
        hlsVariantCount('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8\n'),
        1,
      );
      expect(
        hlsVariantCount(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2\nb.m3u8\n',
        ),
        2,
      );
    });
    test('reads path payload or ?u= fallback', () {
      const encoded = 'aHR0cHM6Ly9leGFtcGxlLmNvbS9hLm0zdTg';
      expect(
        castProxyEncodedPayload(['p', 'token', encoded, 'master.m3u8'], null),
        encoded,
      );
      expect(castProxyEncodedPayload(['p', 'token'], encoded), encoded);
      expect(castProxyEncodedPayload(['p', 'token'], null), isNull);
    });
  });

  group('firstHlsVariantUri', () {
    test('resolves the first STREAM-INF URI against the master base', () {
      const body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
1080p/index.m3u8
''';
      expect(
        firstHlsVariantUri(body, base),
        'https://cdn.example.com/anime/ep1/360p/index.m3u8',
      );
    });
    test('media playlist → null', () {
      expect(
        firstHlsVariantUri('#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n', base),
        isNull,
      );
    });
  });

  group('isUsableCastInterface', () {
    test('accepts real Wi-Fi / ethernet interfaces', () {
      expect(isUsableCastInterface('wlan0'), isTrue);
      expect(isUsableCastInterface('en0'), isTrue);
      expect(isUsableCastInterface('ap0'), isTrue);
    });
    test('rejects VPN / virtual / cellular interfaces', () {
      // The bug: a VPN/hotspot interface IP was advertised to the Chromecast,
      // which can't route to it, so nothing played.
      expect(isUsableCastInterface('tun0'), isFalse);
      expect(isUsableCastInterface('ppp0'), isFalse);
      expect(isUsableCastInterface('rmnet_data0'), isFalse);
      expect(isUsableCastInterface('wg0'), isFalse);
      expect(isUsableCastInterface('utun3'), isFalse);
    });
  });
}
