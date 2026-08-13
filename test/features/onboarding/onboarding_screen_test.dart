import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/features/onboarding/onboarding_screen.dart';

// Onboarding no longer downloads or installs anything — the app ships with
// zero sources, and this screen's job is just to explain that and point the
// user at Providers. "Add sources now" marks onboarded (Hive) then pushes
// ProvidersHubScreen, which pulls in a wide set of DI singletons (CloudStream,
// Aniyomi, LNReader, Mihon managers, ...) that aren't stubbed here, so this
// test covers the initial render only and never taps either button — mirrors
// onboarding_screen_tv_test.dart's same-scoped coverage for the TV screen.
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

  testWidgets(
    'OnboardingScreen renders the welcome + Add sources now + later UI, no install copy',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreen(onDone: () {})),
      );
      await tester.pump();

      expect(find.textContaining('Welcome to'), findsOneWidget);
      expect(find.text('Add sources now'), findsOneWidget);
      expect(find.text("I'll do it later"), findsOneWidget);

      // The old "we'll install the official source catalog" pitch is gone.
      expect(find.textContaining('install the official'), findsNothing);
      expect(find.text('Get Started'), findsNothing);

      // Nothing from the new manga/novel recommended-repo suggestion (Task
      // E4 Part B) leaks into onboarding copy.
      expect(find.textContaining('Sozo'), findsNothing);
      expect(find.textContaining('RECOMMENDED'), findsNothing);
    },
  );
}
