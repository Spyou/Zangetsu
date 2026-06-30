import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_tv_controls.dart';

// ── Minimal stub ──────────────────────────────────────────────────────────────

/// Minimal stub that records calls to [togglePlay] and [seekBy] without
/// bringing in any media_kit / DI infrastructure.
class _FakeController {
  int togglePlayCalls = 0;
  final List<Duration> seekByCalls = [];

  void togglePlay() => togglePlayCalls++;
  void seekBy(Duration d) => seekByCalls.add(d);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Pump [PlayerTvControls] with [barVisible] forwarded to [onBarChange],
/// wired to the given [controller].  [onBack] records whether it was called.
Future<void> _pumpControls(
  WidgetTester tester, {
  required _FakeController controller,
  bool barVisible = false,
  required ValueNotifier<bool> barNotifier,
  required ValueNotifier<bool> backNotifier,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<bool>(
          valueListenable: barNotifier,
          builder: (_, visible, _) => PlayerTvControls(
            onTogglePlay: controller.togglePlay,
            onSeekBy: controller.seekBy,
            onSpeed: () {},
            onAudioSubs: () {},
            onQuality: () {},
            onSources: () {},
            onFit: () {},
            onBack: () => backNotifier.value = true,
            onNext: null,
            barVisible: visible,
            onBarChange: (v) => barNotifier.value = v,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('PlayerTvControls', () {
    late _FakeController controller;
    late ValueNotifier<bool> barNotifier;
    late ValueNotifier<bool> backNotifier;

    setUp(() {
      controller = _FakeController();
      barNotifier = ValueNotifier(false); // bar hidden by default
      backNotifier = ValueNotifier(false);
    });

    tearDown(() {
      barNotifier.dispose();
      backNotifier.dispose();
    });

    testWidgets('arrowRight calls seekBy(+10 s)', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(controller.seekByCalls, contains(const Duration(seconds: 10)));
    });

    testWidgets('arrowLeft calls seekBy(-10 s)', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      expect(controller.seekByCalls, contains(const Duration(seconds: -10)));
    });

    testWidgets('select calls togglePlay', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(controller.togglePlayCalls, 1);
    });

    testWidgets('enter calls togglePlay', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(controller.togglePlayCalls, 1);
    });

    testWidgets('arrowRight also shows bar via onBarChange', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      expect(barNotifier.value, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(); // let the immediate callback fire
      expect(barNotifier.value, isTrue);
    });

    testWidgets('select shows bar via onBarChange', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(barNotifier.value, isTrue);
    });

    testWidgets('arrowDown shows bar', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(barNotifier.value, isTrue);
    });

    testWidgets('Escape hides bar when bar is visible', (tester) async {
      barNotifier.value = true;
      await _pumpControls(
        tester,
        controller: controller,
        barVisible: true,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      // LogicalKeyboardKey.goBack has no physical-key mapping in the test host
      // (desktop), so we use Escape which is also handled as "back".
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(barNotifier.value, isFalse);
      expect(backNotifier.value, isFalse); // onBack NOT called
    });

    testWidgets('Escape calls onBack when bar is hidden', (tester) async {
      await _pumpControls(
        tester,
        controller: controller,
        barVisible: false,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(backNotifier.value, isTrue);
    });

    testWidgets('bar buttons are shown when barVisible is true', (tester) async {
      barNotifier.value = true;
      await _pumpControls(
        tester,
        controller: controller,
        barVisible: true,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      expect(find.text('Speed'), findsOneWidget);
      expect(find.text('Audio & subs'), findsOneWidget);
      expect(find.text('Quality'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Fit'), findsOneWidget);
    });

    testWidgets('onNext button is absent when onNext is null', (tester) async {
      barNotifier.value = true;
      await _pumpControls(
        tester,
        controller: controller,
        barVisible: true,
        barNotifier: barNotifier,
        backNotifier: backNotifier,
      );

      expect(find.text('Next'), findsNothing);
    });

    testWidgets('onNext button appears when onNext is provided', (tester) async {
      barNotifier.value = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: ValueListenableBuilder<bool>(
              valueListenable: barNotifier,
              builder: (_, visible, _) => PlayerTvControls(
                onTogglePlay: controller.togglePlay,
                onSeekBy: controller.seekBy,
                onSpeed: () {},
                onAudioSubs: () {},
                onQuality: () {},
                onSources: () {},
                onFit: () {},
                onBack: () {},
                onNext: () {}, // provided
                barVisible: visible,
                onBarChange: (v) => barNotifier.value = v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Next'), findsOneWidget);
    });
  });
}
