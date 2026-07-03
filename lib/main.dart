import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core/app_config.dart';
import 'core/di/injector.dart';
import 'core/discord/discord_rpc.dart';
import 'core/logging/app_logger.dart';
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
import 'features/watch_together/ui/party_bar.dart';

Future<void> main() async {
  // Run inside a guarded zone so uncaught async errors land in the shareable
  // in-app log (binding + runApp must share this zone — hence both inside).
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLogger.instance.init();
    // Mirror debugPrint into the log (still prints to the console too).
    final origDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) AppLogger.instance.log(message);
      origDebugPrint(message, wrapWidth: wrapWidth);
    };
    // Flutter framework errors → log + normal presentation.
    final origOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      AppLogger.instance.logError(details.exception, details.stack);
      origOnError?.call(details);
    };
    // Cap the in-memory image cache so a heavy source's posters + heroes can't
    // pile up and OOM-crash (default is 100 MB; libmpv adds a big native
    // baseline). On-screen images stay full quality; far-off-screen ones reload
    // from the disk cache.
    PaintingBinding.instance.imageCache.maximumSizeBytes = 80 << 20; // 80 MB
    MediaKit.ensureInitialized();
    // Dependency init happens inside the boot gate so the splash shows
    // immediately instead of a blank screen.
    runApp(const WatchApp());
  }, (error, stack) {
    AppLogger.instance.logError(error, stack);
  });
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

class _WatchAppState extends State<WatchApp> with WidgetsBindingObserver {
  late final Future<void> _boot = _run();
  bool? _onboardedOverride; // set true once onboarding finishes this session
  bool _handledLaunchTaps = false; // route a notification-tap launch once

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!sl.isRegistered<DiscordRpc>()) return;
    if (state == AppLifecycleState.resumed) {
      sl<DiscordRpc>().onForeground();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      sl<DiscordRpc>().onBackground();
    }
  }

  /// Init deps, then (for returning users) kick off the Home fetch so its rows
  /// stream in WHILE the splash plays — Home appears already populated. Holds
  /// the splash for a minimum so the intro animation reads even on fast boots.
  Future<void> _run() async {
    final start = DateTime.now();
    await initDependencies();
    // Show the real build version in Settings/About instead of a stale literal.
    try {
      kAppVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    // Restore a persisted Appwrite session (bounded so a slow network can't
    // trap the splash). If signed in, pull the cloud library into the local
    // cache before Home warms so Continue Watching + My List are populated.
    try {
      await sl<AuthCubit>().restore().timeout(const Duration(seconds: 5));
      if (sl<AuthCubit>().state.isLoggedIn) {
        // Launch path: only re-pull when the local cache is stale (>12h). The
        // library is already cached locally and our own writes push to cloud
        // live, so re-downloading it on every cold start just burns bandwidth.
        // Login (below) and pull-to-refresh still force a full pull.
        await Future.wait([
          sl<MyListStore>().pullFromCloudIfStale(),
          sl<WatchHistory>().pullFromCloudIfStale(),
        ]).timeout(const Duration(seconds: 6));
        // Self-heal: push up any local My List adds that never reached the cloud
        // (e.g. a past write outage). No-op when nothing is pending, so it makes
        // zero writes in normal use. Fire-and-forget so it never delays launch.
        unawaited(sl<MyListStore>().retryPending());
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
      unawaited(sl<MyListStore>().retryPending()); // flush any un-synced adds
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
        // Once the real UI (with the global navigator) is up, open the show if
        // the app was launched by tapping a "new episode" notification.
        if (!_handledLaunchTaps) {
          _handledLaunchTaps = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => NotificationService.instance.handleLaunch(),
          );
        }
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
              navigatorKey: rootNavigatorKey,
              home: home,
              builder: (context, child) => Stack(
                children: [
                  ?child,
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: PartyBar(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
