import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watch_app/features/player/playback_loading_title.dart';

void main() {
  test('artwork keeps cover headers only for the same origin', () {
    const cover = 'https://images.example/cover.jpg';
    const headers = {'Cookie': 'example'};
    expect(
      playbackArtworkHeaders(
        'https://images.example/still.jpg',
        cover,
        headers,
      ),
      headers,
    );
    expect(
      playbackArtworkHeaders('https://other.example/still.jpg', cover, headers),
      isNull,
    );
    expect(
      playbackArtworkHeaders('http://images.example/still.jpg', cover, headers),
      isNull,
    );
    expect(
      playbackArtworkHeaders(
        'https://images.example:8443/still.jpg',
        cover,
        headers,
      ),
      isNull,
    );
  });

  testWidgets('title is visible immediately and keeps pulsing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PlaybackLoadingTitle(title: 'Series', status: 'Starting…'),
      ),
    );
    expect(find.text('Series'), findsOneWidget);
    expect(find.byType(ClipPath), findsNothing);
    final motion = find.byKey(const ValueKey('startup-title-motion'));
    await tester.pump(const Duration(milliseconds: 500));
    final firstScale = tester.widget<Transform>(motion).transform.entry(0, 0);
    await tester.pump(const Duration(milliseconds: 600));
    final nextScale = tester.widget<Transform>(motion).transform.entry(0, 0);
    expect(nextScale, greaterThan(firstScale));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('keeps the title and status visible with reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: PlaybackLoadingTitle(
            title: 'Episode title',
            status: 'Starting playback…',
          ),
        ),
      ),
    );
    expect(find.text('Episode title'), findsOneWidget);
    expect(find.text('Starting playback…'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-title-motion')), findsNothing);
  });
}
