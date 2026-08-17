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

  testWidgets(
    'onSeek fires exactly once, on drag end — never on intermediate ticks',
    (t) async {
      var seekCalls = 0;
      await t.pumpWidget(_host(WatchMiniControls(
        playing: false,
        position: Duration.zero,
        duration: const Duration(minutes: 10),
        onPlayPause: () {},
        onPrevious: null,
        onNext: null,
        onSeek: (_) => seekCalls++,
        onFullscreen: () {},
      )));

      final sliderRect = t.getRect(find.byType(Slider));
      final gesture = await t.startGesture(
        sliderRect.centerLeft + const Offset(5, 0),
      );
      await t.pump();
      expect(seekCalls, 0); // drag started — nothing committed yet

      await gesture.moveBy(const Offset(60, 0));
      await t.pump();
      expect(seekCalls, 0); // mid-drag tick — thumb moves, no seek

      await gesture.moveBy(const Offset(60, 0));
      await t.pump();
      expect(seekCalls, 0); // another mid-drag tick — still no seek

      await gesture.up();
      await t.pump();
      expect(seekCalls, 1); // released — committed exactly once
    },
  );
}
