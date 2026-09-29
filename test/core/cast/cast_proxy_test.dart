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
    expect(
      out,
      contains('/p?u=https://cdn.example.com/anime/ep1/seg0.ts'),
    );
    expect(
      out,
      contains('/p?u=https://cdn.example.com/anime/ep1/seg1.ts'),
    );
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
