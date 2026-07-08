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
}
