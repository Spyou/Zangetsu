import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/tv_playback_launch.dart';

void main() {
  group('tvPlayerKind', () {
    test('Apple TV always uses AVPlayer', () {
      expect(
        tvPlayerKind(appleTv: true, nativeTvPlayer: false),
        TvPlayerKind.avPlayer,
      );
      expect(
        tvPlayerKind(appleTv: true, nativeTvPlayer: true),
        TvPlayerKind.avPlayer,
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
  });
}
