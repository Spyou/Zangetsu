import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/player/tv_playback_launch.dart';

void main() {
  group('tvPlayerKind', () {
    test('Apple TV always uses system AVKit', () {
      expect(
        tvPlayerKind(appleTv: true, nativeTvPlayer: false),
        TvPlayerKind.avPlayerSystem,
      );
      expect(
        tvPlayerKind(appleTv: true, nativeTvPlayer: true),
        TvPlayerKind.avPlayerSystem,
      );
      expect(
        tvPlayerKind(
          appleTv: true,
          nativeTvPlayer: true,
          externalPlayerPackage: 'org.videolan.vlc',
        ),
        TvPlayerKind.avPlayerSystem,
      );
    });

    test('Android TV respects native Exo vs platform view', () {
      expect(
        tvPlayerKind(appleTv: false, nativeTvPlayer: true),
        TvPlayerKind.nativeExo,
      );
      expect(
        tvPlayerKind(appleTv: false, nativeTvPlayer: false),
        TvPlayerKind.exoView,
      );
    });

    test('Android TV uses external when a real package is configured', () {
      expect(
        tvPlayerKind(
          appleTv: false,
          nativeTvPlayer: true,
          externalPlayerPackage: 'org.videolan.vlc',
        ),
        TvPlayerKind.external,
      );
      expect(
        tvPlayerKind(
          appleTv: false,
          nativeTvPlayer: false,
          externalPlayerPackage: 'com.mxtech.videoplayer.ad',
        ),
        TvPlayerKind.external,
      );
    });

    test('empty / Android Player id stay on built-in TV path', () {
      expect(
        tvPlayerKind(
          appleTv: false,
          nativeTvPlayer: true,
          externalPlayerPackage: '',
        ),
        TvPlayerKind.nativeExo,
      );
      expect(
        tvPlayerKind(
          appleTv: false,
          nativeTvPlayer: true,
          externalPlayerPackage: PlaybackPrefs.androidPlayerId,
        ),
        TvPlayerKind.nativeExo,
      );
    });
  });
}
