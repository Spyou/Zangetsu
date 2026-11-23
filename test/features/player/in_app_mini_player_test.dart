import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/episode_player_route.dart';
import 'package:watch_app/features/player/in_app_mini_player.dart';

void main() {
  testWidgets('drag settles into a corner and expand restores playback', (
    tester,
  ) async {
    var restores = 0;
    final systemPip = StreamController<bool>(sync: true);
    addTearDown(systemPip.close);
    const video = ValueKey('video');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              InAppMiniPlayer(
                video: const ColoredBox(key: video, color: Colors.black),
                playing: true,
                systemPipChanges: systemPip.stream,
                playPauseLabel: 'Pause',
                closeLabel: 'Close',
                restoreLabel: 'Restore player',
                onTogglePlayback: () {},
                onClose: () {},
                onRestore: () => restores++,
              ),
            ],
          ),
        ),
      ),
    );

    final initial = tester.getCenter(find.byKey(video));
    final drag = await tester.startGesture(initial.translate(0, -25));
    await drag.moveBy(const Offset(-30, -30));
    await drag.moveBy(const Offset(-420, -210));
    await tester.pump();
    final released = tester.getCenter(find.byKey(video));
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final settling = tester.getCenter(find.byKey(video));
    expect(settling.dx, lessThan(released.dx));
    expect(settling.dy, lessThan(released.dy));
    await tester.pumpAndSettle();
    final moved = tester.getCenter(find.byKey(video));
    expect(moved.dx, lessThan(initial.dx));
    expect(moved.dy, lessThan(initial.dy));
    expect(restores, 0);

    systemPip.add(true);
    await tester.pump();
    final window = tester.getSize(find.byKey(video));
    expect(window, const Size(800, 600));
    expect(find.byIcon(Icons.close_rounded), findsNothing);

    systemPip.add(false);
    await tester.pump();
    expect(tester.getCenter(find.byKey(video)), moved);
    expect(find.byIcon(Icons.close_rounded), findsNothing);

    await tester.tapAt(moved.translate(0, -25));
    await tester.pump();
    expect(restores, 0);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    final close = find.byIcon(Icons.close_rounded);
    final expand = find.byIcon(Icons.open_in_full_rounded);
    expect(tester.getCenter(close).dx, lessThan(moved.dx));
    expect(tester.getCenter(expand).dx, greaterThan(moved.dx));
    await tester.tap(expand);
    expect(restores, 1);
  });

  testWidgets('dock animates in, then grows and fades before expanding', (
    tester,
  ) async {
    final ready = Completer<void>();
    var restored = false;
    const video = ValueKey('entrance-video');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InAppMiniPlayer(
            entranceReady: ready.future,
            video: const ColoredBox(key: video, color: Colors.black),
            playing: true,
            playPauseLabel: 'Pause',
            closeLabel: 'Close',
            restoreLabel: 'Restore player',
            onTogglePlayback: () {},
            onClose: () {},
            onRestore: () => restored = true,
          ),
        ),
      ),
    );

    final finder = find.byKey(video);
    final waiting = tester.getRect(finder);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(finder), waiting);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    ready.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(finder), waiting);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = tester.getRect(finder);
    expect(mid.width, greaterThan(waiting.width));
    expect(mid.width, lessThan(216));
    await tester.pumpAndSettle();
    final dock = tester.getRect(finder);
    expect(dock.width, 216);
    expect(dock.bottomRight - waiting.bottomRight, const Offset(12, 28));
    expect(mid.bottom, inExclusiveRange(waiting.bottom, dock.bottom));
    await tester.tapAt(dock.center);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(finder).width, greaterThan(dock.width));
    expect(restored, isFalse);
    await tester.pumpAndSettle();
    expect(restored, isTrue);
  });

  testWidgets('two fingers resize the card without restoring playback', (
    tester,
  ) async {
    var restores = 0;
    const video = ValueKey('resize-video');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InAppMiniPlayer(
            video: const ColoredBox(key: video, color: Colors.black),
            playing: true,
            playPauseLabel: 'Pause',
            closeLabel: 'Close',
            restoreLabel: 'Restore player',
            onTogglePlayback: () {},
            onClose: () {},
            onRestore: () => restores++,
          ),
        ),
      ),
    );

    Future<void> pinch(double distance) async {
      final finder = find.byKey(video);
      final surfaceSize = tester.getSize(finder);
      final center = tester.getCenter(finder).translate(0, -25);
      final left = await tester.startGesture(center.translate(-35, 0));
      final right = await tester.startGesture(center.translate(35, 0));
      for (var step = 0; step < 4; step++) {
        await left.moveBy(Offset(-distance / 4, 0));
        await right.moveBy(Offset(distance / 4, 0));
        await tester.pump();
      }
      expect(tester.getSize(finder), surfaceSize);
      expect(
        tester.getRect(finder).width,
        isNot(closeTo(surfaceSize.width, 1)),
      );
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
    }

    final initial = tester.getRect(find.byKey(video));
    await pinch(70);
    final larger = tester.getRect(find.byKey(video));
    expect(larger.width, greaterThan(initial.width));
    expect(larger.right, closeTo(initial.right, 1));
    expect(larger.bottom, closeTo(initial.bottom, 1));
    await pinch(-30);
    expect(tester.getSize(find.byKey(video)).width, lessThan(larger.width));
    expect(restores, 0);
  });

  testWidgets('controls leave the browsing surface interactive', (
    tester,
  ) async {
    var browseTaps = 0;
    var toggles = 0;
    var closes = 0;
    const browseButton = ValueKey('browse');
    const preview = ValueKey('control-preview');
    final active = ValueNotifier<InAppMiniPlayer?>(null);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            InAppMiniPlayerHost(dockedPlayer: active, child: child!),
        home: Scaffold(
          body: Center(
            child: TextButton(
              key: browseButton,
              onPressed: () => browseTaps++,
              child: const Text('Browse'),
            ),
          ),
        ),
      ),
    );
    active.value = InAppMiniPlayer(
      video: const ColoredBox(key: preview, color: Colors.black),
      playing: false,
      playPauseLabel: 'Play',
      closeLabel: 'Close',
      restoreLabel: 'Restore player',
      onTogglePlayback: () => toggles++,
      onClose: () {
        closes++;
        active.value = null;
      },
      onRestore: () => fail('Control taps must not restore playback'),
    );
    await tester.pump();

    await tester.tap(find.byKey(browseButton));
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    await tester.tapAt(tester.getCenter(find.byKey(preview)).translate(0, -25));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.tap(find.byIcon(Icons.close_rounded));

    expect(browseTaps, 1);
    expect(toggles, 1);
    expect(closes, 1);
    await tester.pump();
    expect(find.byType(InAppMiniPlayer), findsNothing);
  });

  for (final (platform, native) in [
    (TargetPlatform.android, false),
    (TargetPlatform.android, true),
    (TargetPlatform.iOS, false),
  ]) {
    testWidgets('docking preserves route state ($platform, native=$native)', (
      tester,
    ) async {
      final nav = GlobalKey<NavigatorState>();
      addTearDown(() => dockedPlayer.value = null);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: ThemeData(platform: platform),
          builder: (_, child) =>
              InAppMiniPlayerHost(dockedPlayer: dockedPlayer, child: child!),
          home: const Scaffold(body: Text('Browse')),
        ),
      );
      final key = GlobalKey<_SessionProbeState>();
      final route = EpisodePlayerRoute(
        nativeHandoff: native,
        builder: (_) => _SessionProbe(key: key),
      );
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      final session = key.currentState;

      route.dock(
        (video, restore) => InAppMiniPlayer(
          video: native ? const ColoredBox(color: Colors.black) : video,
          retainedRoute: native ? video : null,
          playing: true,
          playPauseLabel: 'Pause',
          closeLabel: 'Close',
          restoreLabel: 'Restore player',
          onTogglePlayback: () {},
          onClose: () => dockedPlayer.value = null,
          onRestore: restore,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Browse'), findsOneWidget);
      expect(key.currentState, same(session));

      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(110, 130);
      await tester.pumpAndSettle();
      expect(key.currentState, same(session));

      tester.view.resetPhysicalSize();
      await tester.pumpAndSettle();
      dockedPlayer.value!.onRestore();
      await tester.pumpAndSettle();
      expect(find.byType(InAppMiniPlayer), findsNothing);
      expect(key.currentState, same(session));
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(key.currentState, isNull);
    });
  }
}

class _SessionProbe extends StatefulWidget {
  const _SessionProbe({super.key});

  @override
  State<_SessionProbe> createState() => _SessionProbeState();
}

class _SessionProbeState extends State<_SessionProbe> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}
