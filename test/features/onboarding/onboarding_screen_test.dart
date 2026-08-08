import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/features/onboarding/onboarding_screen.dart';

// Task E4 regression guard: Part B adds a *recommended* Zangetsu repo
// suggestion inside the add-repo dialog only. First-launch onboarding
// (lib/features/onboarding/onboarding_screen.dart, kZangetsuRepoUrl seeding)
// must be completely unaffected — nothing here is pre-installed or added to
// the onboarding flow. This mirrors the existing
// onboarding_screen_tv_test.dart's initial-state coverage, for the phone
// screen, to prove that flow still renders identically.
//
// Like the TV test, this only covers the initial (pre-install) state — the
// install path reaches into DI (ProviderReposRegistry, ProviderRegistry,
// ActiveSourceCubit, HomeCubit) which isn't stubbed here. That's fine: it's
// only triggered by pressing "Get Started", which these tests never do.

void main() {
  setUp(() {
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  testWidgets(
    'OnboardingScreen renders the unchanged welcome + Get Started + Skip UI',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreen(onDone: () {})),
      );
      await tester.pump();

      expect(find.textContaining('Welcome to'), findsOneWidget);
      expect(find.text('Get Started'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);

      // Nothing from the new manga/novel recommended-repo suggestion (Task
      // E4 Part B) leaks into onboarding copy.
      expect(find.textContaining('Sozo'), findsNothing);
      expect(find.textContaining('RECOMMENDED'), findsNothing);
    },
  );
}
