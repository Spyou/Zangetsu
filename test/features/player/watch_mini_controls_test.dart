import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/watch_mini_controls.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('play/pause and fullscreen fire their callbacks', (t) async {
    var played = 0, full = 0;
    await t.pumpWidget(_host(WatchMiniControls(
      playing: true,
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 24),
      onPlayPause: () => played++,
      onPrevious: null,
      onNext: () {},
      onSeek: (_) {},
      onFullscreen: () => full++,
    )));

    await t.tap(find.byIcon(Icons.pause_rounded));
    await t.tap(find.byKey(const Key('watch-fullscreen')));
    expect(played, 1);
    expect(full, 1);
  });

  testWidgets('shows position and duration', (t) async {
    await t.pumpWidget(_host(WatchMiniControls(
      playing: false,
      position: const Duration(minutes: 12, seconds: 4),
      duration: const Duration(minutes: 24),
      onPlayPause: () {},
      onPrevious: null,
      onNext: null,
      onSeek: (_) {},
      onFullscreen: () {},
    )));
    expect(find.text('12:04 / 24:00'), findsOneWidget);
  });

  testWidgets('previous is disabled on the first episode', (t) async {
    await t.pumpWidget(_host(WatchMiniControls(
      playing: false,
      position: Duration.zero,
      duration: const Duration(minutes: 24),
      onPlayPause: () {},
      onPrevious: null,
      onNext: () {},
      onSeek: (_) {},
      onFullscreen: () {},
    )));
    final prev = t.widget<IconButton>(find.byKey(const Key('watch-prev')));
    expect(prev.onPressed, isNull);
  });
}
