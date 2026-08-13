import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/onboarding/onboarding_screen_tv.dart';

// ── Tests ─────────────────────────────────────────────────────────────────────
//
// Onboarding no longer downloads or installs anything. These tests cover the
// initial render only — "Add sources now" marks onboarded (Hive) then pushes
// ProvidersHubScreen, which is not stubbed here (it pulls in a wide set of DI
// singletons), so that path is left to integration tests. Pumping
// OnboardingScreenTv with no DI is safe because those calls live in
// _addSourcesNow() / _later(), which only run on button activation.

void main() {
  testWidgets(
    'OnboardingScreenTv renders Add sources now + later buttons with first autofocused',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreenTv(onDone: () {})),
      );
      await tester.pump();

      // Welcome heading is displayed.
      expect(find.textContaining('Welcome to'), findsOneWidget);

      // Both action buttons are rendered in the initial state.
      expect(find.text('Add sources now'), findsOneWidget);
      expect(find.text("I'll do it later"), findsOneWidget);

      // Both buttons are wrapped in TvFocusable for D-pad navigation.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(2));

      // The first TvFocusable (Add sources now) carries autofocus=true so the
      // D-pad lands on it when the screen opens.
      expect(focusables.first.autofocus, isTrue);

      // The second TvFocusable (I'll do it later) has autofocus=false.
      expect(focusables[1].autofocus, isFalse);
    },
  );

  testWidgets(
    'OnboardingScreenTv only the first TvFocusable has autofocus=true',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreenTv(onDone: () {})),
      );
      await tester.pump();

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();

      // Guard: at least one focusable must be built.
      expect(focusables, isNotEmpty);

      // Only the first (Add sources now) carries autofocus.
      expect(focusables.first.autofocus, isTrue);

      // All subsequent TvFocusable widgets have autofocus=false.
      for (final f in focusables.skip(1)) {
        expect(f.autofocus, isFalse);
      }
    },
  );
}
