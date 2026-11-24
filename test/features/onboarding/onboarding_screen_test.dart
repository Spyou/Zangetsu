import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/features/onboarding/onboarding_screen.dart';

// First run: a short logo moment, then the account screen (sign in or
// continue without an account), then hand-off to the profile picker. Here no
// AuthCubit is registered, so there is nothing to ask and the screen hands
// off by itself after the intro. The account screen itself needs a real
// AuthCubit (Supabase) and is covered by on-device checks.

void main() {
  setUp(() {
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  testWidgets('a failed save of the done flag never traps the user', (
    tester,
  ) async {
    // No Hive box is open here, so saving the flag throws.
    var done = false;
    await tester.pumpWidget(
      MaterialApp(home: OnboardingScreen(onDone: () => done = true)),
    );
    expect(done, isFalse);

    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump();
    expect(done, isTrue);
  });
}
