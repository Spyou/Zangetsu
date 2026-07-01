import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/onboarding/onboarding_screen_tv.dart';

// ── Tests ─────────────────────────────────────────────────────────────────────
//
// These tests cover the initial (pre-install) state only. The install path
// calls into DI (ProviderReposRegistry, ProviderRegistry, ActiveSourceCubit,
// HomeCubit) which is not stubbed here — that path is exercised by integration
// tests. Pumping OnboardingScreenTv with no DI is safe because the DI calls
// live in _setup() / _skip(), which are only triggered by button activation.

void main() {
  testWidgets(
    'OnboardingScreenTv renders Get Started + Skip buttons with first autofocused',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreenTv(onDone: () {})),
      );
      await tester.pump();

      // Welcome heading is displayed.
      expect(find.textContaining('Welcome to'), findsOneWidget);

      // Both action buttons are rendered in the initial state.
      expect(find.text('Get Started'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);

      // Both buttons are wrapped in TvFocusable for D-pad navigation.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(2));

      // The first TvFocusable (Get Started) carries autofocus=true so the
      // D-pad lands on it when the screen opens.
      expect(focusables.first.autofocus, isTrue);

      // The second TvFocusable (Skip for now) has autofocus=false.
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

      // Only the first (Get Started) carries autofocus.
      expect(focusables.first.autofocus, isTrue);

      // All subsequent TvFocusable widgets have autofocus=false.
      for (final f in focusables.skip(1)) {
        expect(f.autofocus, isFalse);
      }
    },
  );
}
