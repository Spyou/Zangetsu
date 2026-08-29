import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import 'core/analytics/analytics.dart';
import 'core/app_config.dart';
import 'core/app_mode.dart';
import 'core/di/injector.dart';
import 'core/discord/discord_rpc.dart';
import 'core/environment.dart';
import 'core/logging/app_logger.dart';
import 'core/platform/apple_tv.dart';
import 'core/notify/cs_notify.dart';
import 'core/notify/notification_service.dart';
import 'core/notify/push_service.dart';
import 'core/ui/route_observer.dart';
import 'core/notify/subscription_checker.dart';
import 'core/notify/subscription_store.dart';
import 'core/playback/category_store.dart';
import 'core/playback/my_list.dart';
import 'core/playback/watch_history.dart';
import 'core/reading/read_history.dart';
import 'core/state/active_source_cubit.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/tv/tv_viewport.dart';
import 'core/ui/global_messenger.dart';
import 'features/auth/auth_cubit.dart';
import 'features/home/cubit/home_cubit.dart';
import 'features/onboarding/boot_error_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/root_shell.dart';
import 'features/watch_together/ui/party_bar.dart';

Future<void> main() async {
  // Run inside a guarded zone so uncaught async errors land in the shareable
  // in-app log (binding + runApp must share this zone — hence both inside).
  runZonedGuarded(
    () async {
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
    // Cap the count too — the byte ceiling alone lets lots of small images
    // (cast photos, credits) pile up. 300 is plenty for the visible screens.
    PaintingBinding.instance.imageCache.maximumSize = 300;
    // Fire the list-reveal animations promptly as items scroll in — the
    // detector defaults to a 500ms batch interval, which would blank-flash each
    // card before it reveals.
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 80,
    );
    // Firebase Analytics. Guarded so a build without google-services.json (or a
    // device without Play Services) still boots — analytics just stays off.
    try {
      await Firebase.initializeApp().timeout(const Duration(seconds: 8));
      Analytics.enabled = true;
    } catch (e, st) {
      AppLogger.instance.logError(e, st);
    }
    // Resolve Apple TV before Supabase / media_kit — Dart reports tvOS as iOS,
    // and the version string often has no "tvos" token, so we ask the native
    // runner. Must run before Supabase: its default auth deep-link observer uses
    // app_links, which has no tvOS plugin (MissingPluginException).
    final appleTv = await resolveAppleTv();
    // Bounded + guarded like Firebase/MediaKit: on a dead/slow network the
    // session-restore inside initialize can HANG (a hang never throws, so a
    // try/catch alone wouldn't save us), and this runs BEFORE runApp — an
    // unbounded hang here traps the app on the splash forever. Time it out so
    // boot always proceeds; cloud features degrade to local-only until the next
    // launch on a live network (SupabaseService.currentUserId tolerates an
    // uninitialized client).
    var supabaseOk = false;
    try {
      await Supabase.initialize(
        url: Environment.supabaseUrl,
        anonKey: Environment.supabaseAnonKey,
        // TV auth uses QR pairing, not OAuth redirect deep links.
          authOptions: FlutterAuthClientOptions(detectSessionInUri: !appleTv),
      ).timeout(const Duration(seconds: 8));
      supabaseOk = true;
    } catch (e, st) {
      AppLogger.instance.logError(e, st);
    }
    // Boot init failed (dead/slow network) → keep retrying in the background so
    // login + cloud sync self-heal when the network returns, no restart needed.
    if (!supabaseOk) unawaited(_retrySupabaseInit());
    // media_kit (libmpv) has no tvOS libs — Apple TV plays via AVPlayer instead.
    // Calling ensureInitialized here prints + throws and used to derail boot.
    // On old Android 8 / Fire TV the native libs can also fail to load; guard
    // those so the UI still comes up (playback may be unavailable there).
    if (!appleTv) {
      try {
        MediaKit.ensureInitialized();
      } catch (e, st) {
        AppLogger.instance.logError(e, st);
      }
    }
    // Dependency init happens inside the boot gate so the splash shows
    // immediately instead of a blank screen.
    runApp(const WatchApp());
    },
    (error, stack) {
    AppLogger.instance.logError(error, stack);
    },
  );
}

/// True once Supabase.initialize has set up its singleton. Accessing
/// Supabase.instance asserts when init never ran, so probe it via try/catch.
bool _supabaseReady() {
  try {
    Supabase.instance;
    return true;
  } catch (_) {
    return false;
  }
}

/// After a boot-time Supabase init failure (dead/slow network), keep retrying in
/// the background. Once it comes up, re-run the auth restore so a logged-in
/// user's login + cloud sync reappear WITHOUT an app restart (AuthCubit only
/// restores once, at boot). Fire-and-forget and bounded — gives up quietly if
/// the network stays down (next launch will try again).
Future<void> _retrySupabaseInit() async {
  for (var attempt = 0; attempt < 15; attempt++) {
    await Future.delayed(const Duration(seconds: 15));
    if (_supabaseReady()) break; // a prior attempt already set the client
    try {
      await Supabase.initialize(
        url: Environment.supabaseUrl,
        anonKey: Environment.supabaseAnonKey,
        authOptions: FlutterAuthClientOptions(detectSessionInUri: !isAppleTv),
      ).timeout(const Duration(seconds: 8));
      break; // initialized
    } catch (_) {
      // still down — try again next loop
    }
  }
  // Client is up now → refresh auth so the UI reflects the restored session.
  if (_supabaseReady() && sl.isRegistered<AuthCubit>()) {
    try {
      await sl<AuthCubit>().restore();
    } catch (_) {}
  }
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
  /// Startup, with a watchdog. NOT `late final` — Try again reassigns it.
  late Future<void> _boot = _startBoot();
  bool _bootReady = false;

  /// True once [initDependencies] finishes — cubits exist for the shell route.
  bool _depsReady = false;

  /// True once [Navigator.pushReplacement] has swapped splash → shell (non-tvOS).
  bool _shellRoutePushed = false;

  /// Drives the already-mounted tvOS initial route directly. Rebuilding
  /// MaterialApp does not update that route on physical Apple TV.
  final ValueNotifier<bool> _tvShellGate = ValueNotifier<bool>(false);
  bool _bootFailed = false;
  Object? _bootError;
  StackTrace? _bootStack;

  Future<void> _startBoot() => _run().timeout(const Duration(seconds: 45));

  void _watchBoot(Future<void> boot) {
    boot
        .then((_) {
          if (!mounted) return;
          setState(() => _bootReady = true);
          if (isAppleTv) {
            // Never mount RootShell during pushReplacement on tvOS — building the
            // full shell synchronously wedged the isolate for seconds while the
            // splash frame stayed composited. Load provider JS first, then reveal
            // the already-mounted [_TvBootGate].
            WidgetsBinding.instance.addPostFrameCallback((_) {
              unawaited(_finishAppleTvBoot());
            });
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _pushShellRouteIfNeeded();
            });
          }
          if (!_handledLaunchTaps) {
            _handledLaunchTaps = true;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => NotificationService.instance.handleLaunch(),
            );
          }
        })
        .catchError((Object e, StackTrace st) {
          if (!mounted) return;
          setState(() {
            _bootFailed = true;
            _bootError = e;
            _bootStack = st;
          });
        });
  }

  /// tvOS-only second boot phase: provider eval, then reveal the shell.
  Future<void> _finishAppleTvBoot() async {
    await runDeferredAppleTvBootTasks();
    if (!mounted || !_bootReady || _bootFailed || !_depsReady) {
      debugPrint(
        '[boot] tvOS shell reveal skipped · mounted=$mounted '
        'boot=$_bootReady deps=$_depsReady failed=$_bootFailed',
      );
      return;
    }
    _tvShellGate.value = true;
    setState(() {});
  }

  /// Re-runs startup after a failure. GetIt must be cleared first — every
  /// registerSingleton in initDependencies throws if the type is already
  /// registered, so a bare retry over a partly-built container would fail for
  /// a second, misleading reason.
  Future<void> _retryBoot() async {
    try {
      await sl.reset();
    } catch (_) {
      /* nothing registered yet — fine */
  }
    if (!mounted) return;
    if (!isAppleTv) {
      rootNavigatorKey.currentState?.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const SplashScreen()),
      );
    }
    setState(() {
      _bootReady = false;
      _depsReady = false;
      _shellRoutePushed = false;
      _bootFailed = false;
      _bootError = null;
      _bootStack = null;
      _handledLaunchTaps = false;
      _boot = _startBoot();
    });
    _tvShellGate.value = false;
    _watchBoot(_boot);
  }

  bool? _onboardedOverride; // set true once onboarding finishes this session
  bool _handledLaunchTaps = false; // route a notification-tap launch once

  /// How stale the local library may be before a launch/resume re-pull. Short
  /// enough that switching devices shows fresh data on open, long enough to
  /// debounce app-switching so the DB isn't hammered.
  static const Duration _syncFreshness = Duration(minutes: 2);

  void _onThemeChanged() {
    if (mounted) {
      setState(() {}); // accent changed → rebuild so the app recolours
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ThemeController.revision.addListener(_onThemeChanged);
    _watchBoot(_boot);
  }

  @override
  void dispose() {
    ThemeController.revision.removeListener(_onThemeChanged);
    WidgetsBinding.instance.removeObserver(this);
    _tvShellGate.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final discord = sl.isRegistered<DiscordRpc>() ? sl<DiscordRpc>() : null;
    if (state == AppLifecycleState.resumed) {
      discord?.onForeground();
      _syncOnResume();
      // The wallpaper may have changed while we were away. No-op unless
      // Material You is on, and only rebuilds if the colours actually moved.
      ThemeController.refresh();
    } else if (state == AppLifecycleState.paused) {
      // Opening the in-app player (native surface / immersive) fires paused
      // even though the user is still watching. Do not drop Rich Presence.
      discord?.onPaused();
    } else if (state == AppLifecycleState.detached) {
      discord?.onDetached();
    }
  }

  /// Cross-device freshness: when the app returns to the foreground, re-pull the
  /// library if it's older than [_syncFreshness] (debounced inside
  /// [MyListStore.pullFromCloudIfStale], so rapid app-switching doesn't hammer
  /// the DB). Also flushes any un-synced My List adds.
  void _syncOnResume() {
    if (!sl.isRegistered<AuthCubit>() || !sl<AuthCubit>().state.isLoggedIn) {
      return;
    }
    unawaited(sl<MyListStore>().pullFromCloudIfStale(maxAge: _syncFreshness));
    unawaited(sl<WatchHistory>().pullFromCloudIfStale(maxAge: _syncFreshness));
    unawaited(sl<ReadHistory>().pullFromCloudIfStale(maxAge: _syncFreshness));
    // My List categories ride the same trigger — two small SELECTs, and they
    // have to arrive with the list they label.
    unawaited(sl<CategoryStore>().pullFromCloud());
    unawaited(sl<MyListStore>().retryPending());
  }

  /// Init deps, then (for returning users) kick off the Home fetch so its rows
  /// stream in WHILE the splash plays — Home appears already populated. Holds
  /// the splash for a minimum so the intro animation reads even on fast boots.
  Future<void> _run() async {
    final start = DateTime.now();
    await initDependencies();
    if (mounted) {
      setState(() => _depsReady = true);
      if (_bootReady) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pushShellRouteIfNeeded();
        });
      }
    }
    // Show the real build version in Settings/About instead of a stale literal.
    try {
      final info = await PackageInfo.fromPlatform();
      kAppVersion = info.version;
      AppLogger.instance.log(
        '===== session started · v${info.version} (build ${info.buildNumber}) =====',
      );
    } catch (_) {}
    // Restore a persisted Appwrite session (bounded so a slow network can't
    // trap the splash). If signed in, pull the cloud library into the local
    // cache before Home warms so Continue Watching + My List are populated.
    try {
      await sl<AuthCubit>().restore().timeout(const Duration(seconds: 5));
      if (sl<AuthCubit>().state.isLoggedIn) {
        Future<void> cloudSync() async {
        await Future.wait([
          sl<MyListStore>().seedCloudIfNeeded(),
          sl<WatchHistory>().seedCloudIfNeeded(),
          sl<ReadHistory>().seedCloudIfNeeded(),
        ]).timeout(const Duration(seconds: 8));
        await Future.wait([
          sl<MyListStore>().pullFromCloudIfStale(maxAge: _syncFreshness),
          sl<WatchHistory>().pullFromCloudIfStale(maxAge: _syncFreshness),
          sl<ReadHistory>().pullFromCloudIfStale(maxAge: _syncFreshness),
          sl<CategoryStore>().pullFromCloud(),
        ]).timeout(const Duration(seconds: 6));
        unawaited(sl<MyListStore>().retryPending());
      }

        // tvOS: never block the splash on cloud I/O — sync after the shell is up.
        if (isAppleTv) {
          unawaited(cloudSync().catchError((_) {}));
        } else {
          await cloudSync();
        }
      }
    } catch (_) {}
    if (isOnboarded()) {
      // tvOS: Home fetch waits until provider JS is loaded (deferred boot task).
      if (!isAppleTv) sl<HomeCubit>().load();
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
    // FCM broadcasts: subscribe every device to the `all` topic so we can push
    // a custom notification to all users from the Firebase Console. Independent
    // of onboarding + fire-and-forget so it never delays launch.
    unawaited(PushService.instance.init());
    final elapsed = DateTime.now().difference(start);
    // The intro animation is 1600ms, so anything past that is just dead
    // waiting. Give it a hair over (1700) so the logo lands, then go — used
    // to be 2000ms, which sat there doing nothing for ~400ms.
    const minSplash = Duration(milliseconds: 1700);
    if (elapsed < minSplash) await Future.delayed(minSplash - elapsed);
  }

  /// Cloud-sync the library on in-session auth changes: pull on login, wipe the
  /// local cache on logout. Boot-time restore is handled in [_run] (before this
  /// listener mounts, so no double pull).
  Future<void> _onAuthChange(BuildContext context, AuthState state) async {
    if (state.status == AuthStatus.authenticated) {
      Future<void> sync() async {
      await sl<MyListStore>().seedCloudIfNeeded();
      await sl<WatchHistory>().seedCloudIfNeeded();
      await sl<ReadHistory>().seedCloudIfNeeded();
      await sl<MyListStore>().pullFromCloud();
      await sl<WatchHistory>().pullFromCloud();
      await sl<ReadHistory>().pullFromCloud();
        unawaited(sl<MyListStore>().retryPending());
        if (!isAppleTv || tvosProvidersReady) {
          sl<HomeCubit>().load();
        }
      }

      if (isAppleTv) {
        unawaited(
          sync().timeout(const Duration(seconds: 20)).catchError((_) {}),
        );
      } else {
        await sync();
      }
    } else if (state.status == AuthStatus.unauthenticated) {
      await sl<MyListStore>().clearLocal();
      await sl<WatchHistory>().clearLocal();
      await sl<ReadHistory>().clearLocal();
    }
  }

  Widget _buildShellHome() {
    final onboarded = _onboardedOverride ?? isOnboarded();
    return onboarded
        ? RootShell()
        : OnboardingScreen(
            onDone: () {
              setState(() => _onboardedOverride = true);
              if (isAppleTv) {
                // The Navigator retains its initial _TvBootGate route. Its
                // boolean is already true, so parent setState alone cannot
                // replace the Onboarding child; notify the mounted gate again.
                _tvShellGate
                  ..value = false
                  ..value = true;
              } else {
                rootNavigatorKey.currentState?.pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => RootShell()),
          );
              }
            },
          );
        }

  /// Swaps the splash route for the real shell (phone / Android TV only).
  void _pushShellRouteIfNeeded() {
    if (isAppleTv) return;
    if (_shellRoutePushed || !_bootReady || _bootFailed || !_depsReady) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => _buildShellHome(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
          );
    _shellRoutePushed = true;
    if (mounted) setState(() {});
        }

  Widget _buildHome() {
    if (_bootFailed) {
      AppLogger.instance.logError(_bootError ?? 'startup failed', _bootStack);
      return BootErrorScreen(
        details: '$_bootError\n\n${_bootStack ?? ''}'.trim(),
        onRetry: _retryBoot,
              );
    }
    if (isAppleTv) {
      // Keep ONE widget as [MaterialApp.home] for the app lifetime — changing
      // `home` from SplashScreen to RootShell does not replace the Navigator's
      // initial route on tvOS (logs show "shell visible" while splash stays up).
      return _TvBootGate(
        showShell: _tvShellGate,
        shellBuilder: _buildShellHome,
          );
        }
    return const SplashScreen();
  }

  Widget _buildMaterialApp({required bool shellFeatures}) {
    return MaterialApp(
              title: kAppName,
              theme: buildAppTheme(),
              debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: shellFeatures ? rootMessengerKey : null,
              navigatorKey: rootNavigatorKey,
      navigatorObservers: shellFeatures
          ? [Analytics.observer, appRouteObserver]
          : const [],
      home: _buildHome(),
      builder: (_, child) {
        final content = shellFeatures
            ? Stack(
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
              )
            : (child ?? const SizedBox.shrink());
        final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
        return isTv ? TvViewport(child: content) : content;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final shellFeatures = isAppleTv
        ? (_tvShellGate.value && _depsReady && !_bootFailed)
        : (_shellRoutePushed && !_bootFailed);
    final app = _buildMaterialApp(shellFeatures: shellFeatures);

    if (!_depsReady) return app;

    return MultiBlocProvider(
      providers: [
        BlocProvider<ActiveSourceCubit>.value(value: sl<ActiveSourceCubit>()),
        BlocProvider<AuthCubit>.value(value: sl<AuthCubit>()),
      ],
      child: BlocListener<AuthCubit, AuthState>(
        listenWhen: (p, c) => p.status != c.status,
        listener: _onAuthChange,
        child: app,
          ),
        );
  }
}

/// tvOS boot gate: always the [MaterialApp.home] route so toggling [showShell]
/// swaps children in-place instead of changing `home` (which does not replace
/// the Navigator's initial route after first paint on physical Apple TV).
class _TvBootGate extends StatelessWidget {
  const _TvBootGate({required this.showShell, required this.shellBuilder});

  final ValueListenable<bool> showShell;
  final Widget Function() shellBuilder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: showShell,
      builder: (_, visible, _) {
        if (visible) return RepaintBoundary(child: shellBuilder());
        return const SplashScreen();
      },
    );
  }
}
