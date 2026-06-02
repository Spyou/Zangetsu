import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';

import 'core/app_config.dart';
import 'core/di/injector.dart';
import 'core/state/active_source_cubit.dart';
import 'core/theme/app_theme.dart';
import 'features/home/cubit/home_cubit.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/root_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Dependency init now happens inside the boot gate so the splash shows
  // immediately instead of a blank screen.
  runApp(const WatchApp());
}

class WatchApp extends StatelessWidget {
  const WatchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: kAppName,
    theme: buildAppTheme(),
    debugShowCheckedModeBanner: false,
    home: const _BootGate(),
  );
}

/// Boots the app: runs [initDependencies] behind a splash, then routes to
/// first-run onboarding (download the Zangetsu provider repo) or the shell.
class _BootGate extends StatefulWidget {
  const _BootGate();

  @override
  State<_BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<_BootGate> {
  late final Future<void> _boot = _run();
  bool? _onboardedOverride; // set true once onboarding finishes this session

  /// Init deps, then (for returning users) kick off the Home fetch so its rows
  /// stream in WHILE the splash plays — Home appears already populated. Holds
  /// the splash for a minimum so the intro animation reads even on fast boots.
  Future<void> _run() async {
    final start = DateTime.now();
    await initDependencies();
    if (isOnboarded()) {
      sl<HomeCubit>().load(); // fire-and-forget warm for the active source
    }
    final elapsed = DateTime.now().difference(start);
    const minSplash = Duration(milliseconds: 2000);
    if (elapsed < minSplash) await Future.delayed(minSplash - elapsed);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _boot,
      builder: (context, snap) {
        // Still initializing (or init failed) → keep the splash up.
        if (snap.connectionState != ConnectionState.done || snap.hasError) {
          return const SplashScreen();
        }
        // Dependencies ready — sl<> is resolvable from here on.
        final onboarded = _onboardedOverride ?? isOnboarded();
        final Widget child = onboarded
            ? const RootShell()
            : OnboardingScreen(
                onDone: () => setState(() => _onboardedOverride = true),
              );
        return MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: sl<ActiveSourceCubit>()),
          ],
          child: child,
        );
      },
    );
  }
}
