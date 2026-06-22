import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';

import 'core/app_config.dart';
import 'core/di/injector.dart';
import 'core/notify/cs_notify.dart';
import 'core/notify/notification_service.dart';
import 'core/notify/subscription_checker.dart';
import 'core/notify/subscription_store.dart';
import 'core/playback/my_list.dart';
import 'core/playback/watch_history.dart';
import 'core/state/active_source_cubit.dart';
import 'core/theme/app_theme.dart';
import 'core/ui/global_messenger.dart';
import 'features/auth/auth_cubit.dart';
import 'features/home/cubit/home_cubit.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/root_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Dependency init happens inside the boot gate so the splash shows
  // immediately instead of a blank screen.
  runApp(const WatchApp());
}

/// Boots the app: runs [initDependencies] behind a splash, then builds the
/// real app with the global cubits provided ABOVE the [MaterialApp]'s Navigator
/// so pushed routes (login, profile, …) can read them. Providing them below the
/// Navigator would scope them out of any `Navigator.push`ed route.
class WatchApp extends StatefulWidget {
  const WatchApp({super.key});

  @override
  State<WatchApp> createState() => _WatchAppState();
}

class _WatchAppState extends State<WatchApp> {
  late final Future<void> _boot = _run();
  bool? _onboardedOverride; // set true once onboarding finishes this session

  /// Init deps, then (for returning users) kick off the Home fetch so its rows
  /// stream in WHILE the splash plays — Home appears already populated. Holds
  /// the splash for a minimum so the intro animation reads even on fast boots.
  Future<void> _run() async {
    final start = DateTime.now();
    await initDependencies();
    // Restore a persisted Appwrite session (bounded so a slow network can't
    // trap the splash). If signed in, pull the cloud library into the local
    // cache before Home warms so Continue Watching + My List are populated.
    try {
      await sl<AuthCubit>().restore().timeout(const Duration(seconds: 5));
      if (sl<AuthCubit>().state.isLoggedIn) {
        await Future.wait([
          sl<MyListStore>().pullFromCloud(),
          sl<WatchHistory>().pullFromCloud(),
        ]).timeout(const Duration(seconds: 6));
      }
    } catch (_) {}
    if (isOnboarded()) {
      sl<HomeCubit>().load(); // fire-and-forget warm for the active source
      // CloudStream-style "new episode" check: once the app is up, re-fetch
      // each subscribed show's episodes (JS or CS) and notify on any increase.
      // Fire-and-forget + delayed so it doesn't compete with the splash/home.
      Future.delayed(const Duration(seconds: 6), () async {
        try {
          await NotificationService.instance.init();
          // Mirror CS subs to native + (re)schedule the background worker, then
          // run the launch sweep: JS sources here, CS via the native worker.
          await CsNotify.sync(sl<SubscriptionStore>().all());
          await sl<SubscriptionChecker>().checkAll();
          await CsNotify.checkNow();
        } catch (_) {}
      });
    }
    final elapsed = DateTime.now().difference(start);
    const minSplash = Duration(milliseconds: 2000);
    if (elapsed < minSplash) await Future.delayed(minSplash - elapsed);
  }

  /// Cloud-sync the library on in-session auth changes: pull on login, wipe the
  /// local cache on logout. Boot-time restore is handled in [_run] (before this
  /// listener mounts, so no double pull).
  Future<void> _onAuthChange(BuildContext context, AuthState state) async {
    if (state.status == AuthStatus.authenticated) {
      await sl<MyListStore>().pullFromCloud();
      await sl<WatchHistory>().pullFromCloud();
      sl<HomeCubit>().load(); // surface pulled Continue Watching
    } else if (state.status == AuthStatus.unauthenticated) {
      await sl<MyListStore>().clearLocal();
      await sl<WatchHistory>().clearLocal();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _boot,
      builder: (context, snap) {
        // Still initializing (or init failed) → keep the splash up. No cubits
        // are needed yet, so a bare MaterialApp is enough.
        if (snap.connectionState != ConnectionState.done || snap.hasError) {
          return MaterialApp(
            title: kAppName,
            theme: buildAppTheme(),
            debugShowCheckedModeBanner: false,
            home: const SplashScreen(),
          );
        }
        // Dependencies ready — sl<> is resolvable from here on.
        final onboarded = _onboardedOverride ?? isOnboarded();
        final Widget home = onboarded
            ? const RootShell()
            : OnboardingScreen(
                onDone: () => setState(() => _onboardedOverride = true),
              );
        // Providers wrap the MaterialApp so its Navigator (and every pushed
        // route) is a descendant of them.
        return MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: sl<ActiveSourceCubit>()),
            BlocProvider<AuthCubit>.value(value: sl<AuthCubit>()),
          ],
          child: BlocListener<AuthCubit, AuthState>(
            listenWhen: (p, c) => p.status != c.status,
            listener: _onAuthChange,
            child: MaterialApp(
              title: kAppName,
              theme: buildAppTheme(),
              debugShowCheckedModeBanner: false,
              scaffoldMessengerKey: rootMessengerKey,
              home: home,
            ),
          ),
        );
      },
    );
  }
}
