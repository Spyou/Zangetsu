import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  group('rotation presentation', () {
    test('portrait turn in fullscreen returns to the watch page', () {
      expect(
        rotationPresentation(
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
          last: Orientation.portrait,
          current: Orientation.landscape,
          presentation: PlayerPresentation.watchPage,
        ),
        PlayerPresentation.fullscreen,
      );
    });

    test('landscape turn already fullscreen stays', () {
      expect(
        rotationPresentation(
          last: Orientation.portrait,
          current: Orientation.landscape,
          presentation: PlayerPresentation.fullscreen,
        ),
        isNull,
      );
    });

    test('no turn means no switch', () {
      expect(
        rotationPresentation(
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
          last: null,
          current: Orientation.portrait,
          presentation: PlayerPresentation.fullscreen,
        ),
        isNull,
      );
    });
  });

  group('initial player presentation', () {
    test('TV always opens fullscreen', () {
      expect(
        initialPresentation(
          isTv: true,
          orientation: 'system',
          isLandscape: false,
        ),
        PlayerPresentation.fullscreen,
      );
    });

    test('phone landscape lock opens fullscreen', () {
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'landscape',
          isLandscape: false,
        ),
        PlayerPresentation.fullscreen,
      );
    });

    test('phone portrait lock opens the watch page', () {
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'portrait',
          isLandscape: false,
        ),
        PlayerPresentation.watchPage,
      );
    });

    test('portrait preference opens the page even from a landscape screen', () {
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'portrait',
          isLandscape: true,
        ),
        PlayerPresentation.watchPage,
      );
    });
    test('unknown orientation keeps the landscape default', () {
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'unknown',
          isLandscape: false,
        ),
        PlayerPresentation.fullscreen,
      );
    });

    test('system orientation starts in the portrait watch page', () {
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'system',
          isLandscape: false,
        ),
        PlayerPresentation.watchPage,
      );
    });

    test('system orientation already in landscape opens fullscreen', () {
      expect(
        initialPresentation(
          isTv: false,
          orientation: 'system',
          isLandscape: true,
        ),
        PlayerPresentation.fullscreen,
      );
    });
  });
}
