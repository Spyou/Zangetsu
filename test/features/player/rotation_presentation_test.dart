import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  group('rotation presentation', () {
    test('portrait turn in fullscreen lands on the watch page', () {
      expect(
        rotationPresentation(
          watchPageEnabled: true,
          systemSensor: true,
          last: Orientation.landscape,
          current: Orientation.portrait,
          presentation: PlayerPresentation.fullscreen,
        ),
        PlayerPresentation.watchPage,
      );
    });

    test('landscape turn on the page goes fullscreen', () {
      expect(
        rotationPresentation(
          watchPageEnabled: true,
          systemSensor: true,
          last: Orientation.portrait,
          current: Orientation.landscape,
          presentation: PlayerPresentation.watchPage,
        ),
        PlayerPresentation.fullscreen,
      );
    });

    test('no turn means no switch', () {
      expect(
        rotationPresentation(
          watchPageEnabled: true,
          systemSensor: true,
          last: Orientation.portrait,
          current: Orientation.portrait,
          presentation: PlayerPresentation.fullscreen,
        ),
        isNull,
      );
    });

    test('first build never switches', () {
      expect(
        rotationPresentation(
          watchPageEnabled: true,
          systemSensor: true,
          last: null,
          current: Orientation.portrait,
          presentation: PlayerPresentation.fullscreen,
        ),
        isNull,
      );
    });

    test('locked orientation never switches', () {
      expect(
        rotationPresentation(
          watchPageEnabled: true,
          systemSensor: false,
          last: Orientation.landscape,
          current: Orientation.portrait,
          presentation: PlayerPresentation.fullscreen,
        ),
        isNull,
      );
    });

    test('watch page off never switches', () {
      expect(
        rotationPresentation(
          watchPageEnabled: false,
          systemSensor: true,
          last: Orientation.landscape,
          current: Orientation.portrait,
          presentation: PlayerPresentation.fullscreen,
        ),
        isNull,
      );
    });
  });
}
