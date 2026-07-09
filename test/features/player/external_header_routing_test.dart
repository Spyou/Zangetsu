import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  group('headerGatedButPlayerCant (route header-gated sources to built-in)', () {
    const vlc = 'org.videolan.vlc';
    const mx = 'com.mxtech.videoplayer.ad';
    const mxPro = 'com.mxtech.videoplayer.pro';
    const just = 'com.brouken.player';
    const splayer = 'com.young.simple.player'; // an SPlayer-style package

    test('header-gated source + VLC/SPlayer/other → true (route to built-in)', () {
      const gated = {'Referer': 'https://x/', 'User-Agent': 'UA'};
      expect(headerGatedButPlayerCant(gated, vlc), isTrue);
      expect(headerGatedButPlayerCant(gated, splayer), isTrue);
      expect(headerGatedButPlayerCant({'Origin': 'x'}, vlc), isTrue);
      expect(headerGatedButPlayerCant({'Cookie': 'x'}, vlc), isTrue);
    });

    test('header-gated source + header-forwarding player → false (let it play)', () {
      const gated = {'Referer': 'https://x/'};
      expect(headerGatedButPlayerCant(gated, mx), isFalse);
      expect(headerGatedButPlayerCant(gated, mxPro), isFalse);
      expect(headerGatedButPlayerCant(gated, just), isFalse);
    });

    test('no gating header (or only User-Agent) → false for any player', () {
      expect(headerGatedButPlayerCant({'User-Agent': 'UA'}, vlc), isFalse);
      expect(headerGatedButPlayerCant(const {}, vlc), isFalse);
      expect(headerGatedButPlayerCant(null, vlc), isFalse);
    });

    test('header keys are case-insensitive', () {
      expect(headerGatedButPlayerCant({'referer': 'x'}, vlc), isTrue);
      expect(headerGatedButPlayerCant({'ORIGIN': 'x'}, vlc), isTrue);
    });

    test('empty package (system chooser / built-in) → false (do not pre-route)', () {
      expect(headerGatedButPlayerCant({'Referer': 'x'}, ''), isFalse);
    });
  });

  group('isLocalStreamUrl (already-proxied CloudStream sources pass through)', () {
    test('localhost / 127.0.0.1 (http+https) → true', () {
      expect(isLocalStreamUrl('http://localhost:36107/m3u8?x=1'), isTrue);
      expect(isLocalStreamUrl('http://127.0.0.1:37317/s/abc'), isTrue);
      expect(isLocalStreamUrl('https://localhost:8080/x'), isTrue);
      expect(isLocalStreamUrl('HTTP://127.0.0.1/x'), isTrue);
    });
    test('remote URLs → false', () {
      expect(isLocalStreamUrl('https://cdn.mewstream.buzz/x/index.m3u8'), isFalse);
      expect(isLocalStreamUrl('https://vivibebe.site/stream/1080.m3u8'), isFalse);
    });
  });

  group('isDashUrl (.mpd routes to built-in)', () {
    test('.mpd (with/without query) → true', () {
      expect(isDashUrl('https://sacdn.hakunaymatata.com/dash/1_h265/index_web.mpd'), isTrue);
      expect(isDashUrl('https://x/manifest.mpd?token=abc'), isTrue);
      expect(isDashUrl('https://X/INDEX.MPD'), isTrue);
    });
    test('HLS / other → false', () {
      expect(isDashUrl('https://cdn.mewstream.buzz/x/index.m3u8'), isFalse);
      expect(isDashUrl('https://x/movie.mp4'), isFalse);
    });
  });
}
