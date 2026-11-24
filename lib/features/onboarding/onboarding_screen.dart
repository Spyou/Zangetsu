import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ui/splash_style.dart';
import 'bankai_splash.dart';
import 'package:hive/hive.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../auth/auth_cubit.dart';
import 'onboarding_pages.dart';
import 'onboarding_screen_tv.dart';

/// First-run flag, stored in the shared 'app_prefs' Hive box (opened during
/// [initDependencies]). True once the user has completed onboarding.
bool isOnboarded() {
  if (!Hive.isBoxOpen(ActiveSourceCubit.boxName)) return false;
  return Hive.box(
        ActiveSourceCubit.boxName,
      ).get('onboarded', defaultValue: false)
      as bool;
}

Future<void> _markOnboarded() =>
    Hive.box(ActiveSourceCubit.boxName).put('onboarded', true);

// ─────────────────────────────────────────────────────────────────────────────
// Splash — shown while initDependencies() runs.
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..forward();

  // Glow eases in; the wordmark fades in and "draws" left→right (wipe reveal)
  // while settling up to full scale; the loader appears last.
  late final Animation<double> _glow = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.12, 0.5, curve: Curves.easeOut),
  );
  late final Animation<double> _reveal = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.12, 1.0, curve: Curves.easeOutCubic),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Read once, at the start of the animation — the picker writes the box, and
  /// re-reading mid-build would let a change take effect halfway through a run.
  late final bool _bankai = SplashStyle.selectedId == 'bankai';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // The mark being cut in, driven by the same controller — one ticker
          // either way, so picking it costs nothing the wordmark did not.
          if (_bankai) {
            return Center(
              child: LayoutBuilder(
                builder: (context, box) => BankaiSplash(
                  progress: _c.value,
                  size: math.min(box.maxWidth * 0.62, 320),
                ),
              ),
            );
          }
          final r = _reveal.value;
          return Stack(
            children: [
              // Soft coral glow behind the wordmark — echoes the logo's circle.
              Center(
                child: Opacity(
                  opacity: _glow.value,
                  child: Container(
                    width: 460,
                    height: 460,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AppColors.accent.withValues(alpha: 0.18),
                          AppColors.accent.withValues(alpha: 0.05),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // Wordmark — wipe reveal (left→right) + fade + slight scale settle.
              Center(
                child: FractionallySizedBox(
                  widthFactor: 0.62,
                  child: Opacity(
                    opacity: _fade.value,
                    child: Transform.scale(
                      scale: 0.94 + 0.06 * r,
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (rect) => LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: const [
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [
                            0.0,
                            (r - 0.07).clamp(0.0, 1.0),
                            r.clamp(0.0001, 1.0),
                          ],
                        ).createShader(rect),
                        child: Image.asset(
                          'assets/icon/wordmark.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Onboarding — first launch. A short logo moment, then the account screen
// (sign in, sign up, or continue without an account), then the profile
// picker and the app via [onDone]. Nothing here downloads or installs anything.
// ─────────────────────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onDone,
    this.replay = false,
  });

  /// Called once setup completes — the boot gate then shows the profile
  /// picker and the app.
  final VoidCallback onDone;

  /// Opened from Settings → How it works: runs the same screens again.
  final bool replay;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _introDone = false;
  bool _finished = false;
  Timer? _introTimer;
  List<String> _posters = const [];

  /// The account screen only appears when sign-in exists and nobody is signed
  /// in already (or when replaying from Settings).
  bool get _needsAccount =>
      sl.isRegistered<AuthCubit>() &&
      (widget.replay || !sl<AuthCubit>().state.isLoggedIn);

  @override
  void initState() {
    super.initState();
    unawaited(
      fetchOnboardingPosters().then((p) {
        if (mounted && p.isNotEmpty) setState(() => _posters = p);
      }),
    );
    // A short logo moment, then the account screen (or straight on when
    // there's nothing to ask).
    _introTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      if (_needsAccount) {
        setState(() => _introDone = true);
      } else {
        _complete();
      }
    });
  }

  @override
  void dispose() {
    _introTimer?.cancel();
    super.dispose();
  }

  /// Marks onboarding done and hands over. Runs once, however it's reached
  /// (guest button, sign-in or sign-up).
  Future<void> _complete() async {
    if (_finished) return;
    _finished = true;
    // A failed write must never trap someone here: worst case they see
    // onboarding once more on the next launch.
    try {
      await _markOnboarded();
    } catch (e) {
      debugPrint('[onboarding] could not save the done flag: $e');
    }
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return OnboardingScreenTv(onDone: widget.onDone);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: OnbPosterWall(posters: _posters, animate: !_introDone),
          ),
          // Dims the wall behind the form. A plain colour overlay, not an
          // Opacity layer, so the huge wall isn't rendered off-screen.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 450),
                color: AppColors.bg.withValues(alpha: _introDone ? 0.75 : 0.15),
              ),
            ),
          ),
          // Soft edges: posters dissolve into the background all round.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.25),
                    radius: 1.0,
                    colors: [
                      Colors.transparent,
                      AppColors.bg.withValues(alpha: 0.55),
                      AppColors.bg.withValues(alpha: 0.95),
                    ],
                    stops: const [0.35, 0.75, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.bg.withValues(alpha: 0.2),
                    AppColors.bg.withValues(alpha: 0.78),
                    AppColors.bg,
                  ],
                  stops: const [0, 0.45, 0.78],
                ),
              ),
            ),
          ),
          SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              // Fill the screen: the default layout sizes the stack to its
              // child, which pinned the intro to a narrow strip on the left.
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, ?current],
              ),
              child: _introDone
                  ? OnbAccountPage(
                      key: const ValueKey('account'),
                      active: true,
                      onNext: _complete,
                    )
                  : const OnbBrandPage(key: ValueKey('intro'), active: true),
            ),
          ),
        ],
      ),
    );
  }
}
