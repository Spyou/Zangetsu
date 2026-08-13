import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/onboarding/onboarding_screen.dart';

// Onboarding no longer downloads or installs anything — the app ships with
// zero sources, and this screen's job is just to explain that and point the
// user at Providers. It's now three swiped pages (brand → how sources work →
// the hand-off); "Add sources now" and "I'll do it later" only render on the
// last page, which the tests below jump to directly via the PageView's own
// controller (no drag simulation needed — PageController is public API).
//
// "Add sources now" is never tapped here — it pushes ProvidersHubScreen,
// which pulls in a wide set of DI singletons (CloudStream, Aniyomi, LNReader,
// Mihon managers, ...) not stubbed in this test, mirroring
// onboarding_screen_tv_test.dart's same-scoped coverage for the TV screen.
// "I'll do it later" only touches Hive, so it's exercised directly to cover
// the mark-onboarded behavior.
//
// Also a regression guard from Task E4: Part B's *recommended* Zangetsu repo
// suggestion lives inside the add-repo dialog only and must never leak into
// this welcome copy.

void main() {
  setUp(() {
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  testWidgets('opens on the brand page, no old install copy', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: OnboardingScreen(onDone: () {})),
    );
    await tester.pump();

    // First page is the brand/positioning page, not the hand-off buttons.
    expect(find.textContaining('Anime'), findsOneWidget);

    // The old "we'll install the official source catalog" pitch is gone.
    expect(find.textContaining('install the official'), findsNothing);
    expect(find.text('Get Started'), findsNothing);

    // Nothing from the new manga/novel recommended-repo suggestion (Task
    // E4 Part B) leaks into onboarding copy.
    expect(find.textContaining('Sozo'), findsNothing);
    expect(find.textContaining('RECOMMENDED'), findsNothing);
  });

  testWidgets("last page renders Add sources now + I'll do it later", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: OnboardingScreen(onDone: () {})),
    );
    await tester.pump();

    final PageView pageView = tester.widget(find.byType(PageView));
    pageView.controller!.jumpToPage(2);
    await tester.pumpAndSettle();

    expect(find.text('Add sources now'), findsOneWidget);
    expect(find.text("I'll do it later"), findsOneWidget);
  });

  group('marks onboarded (Hive-backed)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('onboarding_test');
      Hive.init(dir.path);
      await Hive.openBox(ActiveSourceCubit.boxName);
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    testWidgets("I'll do it later marks onboarded and calls onDone", (
      tester,
    ) async {
      var done = false;
      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreen(onDone: () => done = true)),
      );
      await tester.pump();

      final PageView pageView = tester.widget(find.byType(PageView));
      pageView.controller!.jumpToPage(2);
      await tester.pumpAndSettle();

      expect(isOnboarded(), isFalse);
      // runAsync, not a bare tap + pumps: `_later()` awaits a REAL Hive disk
      // write, and a real I/O future never resolves under the widget test's
      // fake-async zone — so `onDone` would never run and this would fail even
      // though the button works fine in the app. runAsync forwards to the real
      // event loop so the write (and its continuation) actually completes.
      await tester.runAsync(() async {
        await tester.tap(find.text("I'll do it later"));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(done, isTrue);
      expect(isOnboarded(), isTrue);
    });
  });
}
