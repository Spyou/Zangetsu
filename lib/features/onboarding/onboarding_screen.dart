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
import '../../core/theme/app_text.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../auth/auth_cubit.dart';
import '../sources/providers_hub_screen.dart';
import '../../core/theme/theme_controller.dart';
import 'onboarding_pages.dart';
import 'onboarding_screen_tv.dart';
import '../../l10n/l10n.dart';

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
// Onboarding — first launch. Brand → account (sign in or guest) → look →
// interests → hand-off. The app ships with NO sources installed, so the last
// page points the user at Providers to add their own repository, then hands
// off to the app via [onDone]. Nothing here downloads or installs anything.
// ─────────────────────────────────────────────────────────────────────────────

enum _Step { brand, account, look, interests, finish }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onDone,
    this.replay = false,
  });

  /// Opened from Settings → How it works: runs the same pages again.
  final bool replay;

  /// Called once setup completes (or is skipped) — the boot gate then shows
  /// the app shell.
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  double _page = 0;
  late ContentMode _kind = sl.isRegistered<ContentModeCubit>()
      ? sl<ContentModeCubit>().state
      : ContentMode.anime;
  List<String> _posters = const [];

  /// The account page only appears when sign-in exists and nobody is signed in
  /// already (e.g. after a restore).
  late final List<_Step> _steps = [
    _Step.brand,
    if (sl.isRegistered<AuthCubit>() && !sl<AuthCubit>().state.isLoggedIn)
      _Step.account,
    _Step.look,
    _Step.interests,
    _Step.finish,
  ];

  int get _index => _page.round().clamp(0, _steps.length - 1);
  _Step get _current => _steps[_index];

  @override
  void initState() {
    super.initState();
    unawaited(
      fetchOnboardingPosters().then((p) {
        if (mounted && p.isNotEmpty) setState(() => _posters = p);
      }),
    );
    _controller.addListener(() {
      final p = _controller.page;
      if (p != null) setState(() => _page = p);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Opens the app on the chosen kind of content, then marks onboarding done.
  Future<void> _finish() async {
    if (sl.isRegistered<ContentModeCubit>() &&
        sl<ContentModeCubit>().state != _kind) {
      unawaited(sl<ContentModeCubit>().setMode(_kind));
    }
    // A failed write must never trap someone here: worst case they see
    // onboarding once more on the next launch.
    try {
      await _markOnboarded();
    } catch (e) {
      debugPrint('[onboarding] could not save the done flag: $e');
    }
  }

  Future<void> _addSourcesNow() async {
    await _finish();
    if (!mounted) return;
    final nav = Navigator.of(context);
    widget.onDone();
    nav.push(
      MaterialPageRoute<void>(builder: (_) => const ProvidersHubScreen()),
    );
  }

  Future<void> _later() async {
    await _finish();
    if (mounted) widget.onDone();
  }

  void _next() => _controller.nextPage(
    duration: const Duration(milliseconds: 420),
    curve: Curves.easeOutCubic,
  );

  void _pickKind(ContentMode m) => setState(() => _kind = m);

  Widget _pageFor(_Step step, bool active) => switch (step) {
    _Step.brand => OnbBrandPage(active: active),
    _Step.account => OnbAccountPage(active: active, onNext: _next),
    _Step.look => OnbLookPage(active: active),
    _Step.interests => OnbInterestsPage(
      active: active,
      selected: _kind,
      onSelect: _pickKind,
    ),
    _Step.finish => OnbFinishPage(
      active: active,
      onAddSourcesNow: _addSourcesNow,
      onLater: _later,
    ),
  };

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return OnboardingScreenTv(onDone: widget.onDone);
    final onLast = _current == _Step.finish;
    // The account page has its own buttons; the other pages share one footer.
    final showNext = !onLast && _current != _Step.account;
    final dim = (_page / 0.7).clamp(0.0, 1.0);
    return ValueListenableBuilder<int>(
      valueListenable: ThemeController.revision,
      builder: (context, _, _) => _scaffold(context, onLast, showNext, dim),
    );
  }

  Widget _scaffold(
    BuildContext context,
    bool onLast,
    bool showNext,
    double dim,
  ) {
    return PopScope(
      // Back steps to the previous page; only the first page leaves.
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _controller.previousPage(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          );
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0.85 - 0.6 * dim,
                child: OnbPosterWall(posters: _posters, animate: dim < 1),
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
              child: Stack(
                children: [
                  PageView(
                    controller: _controller,
                    children: [
                      for (var i = 0; i < _steps.length; i++)
                        _pageFor(_steps[i], i == _index),
                    ],
                  ),
                  Positioned(
                    top: 4,
                    right: 12,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: onLast ? 0 : 1,
                      child: IgnorePointer(
                        ignoring: onLast,
                        child: TextButton(
                          onPressed: _later,
                          child: Text(
                            context.l10n.skip,
                            style: AppText.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 26,
                    right: 26,
                    bottom: 24,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Progress(page: _page, count: _steps.length),
                        const SizedBox(height: 18),
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: showNext ? 1 : 0,
                          child: IgnorePointer(
                            ignoring: !showNext,
                            child: SizedBox(
                              width: double.infinity,
                              height: 54,
                              child: FilledButton(
                                onPressed: _next,
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(27),
                                  ),
                                ),
                                child: Text(
                                  _current == _Step.brand
                                      ? 'Get started'
                                      : context.l10n.continueLabel,
                                  style: AppText.button.copyWith(
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Progress pills: the current page stretches into a bar and earlier pages
/// stay tinted.
class _Progress extends StatelessWidget {
  const _Progress({required this.page, required this.count});

  final double page;
  final int count;

  @override
  Widget build(BuildContext context) {
    final current = page.round().clamp(0, count - 1);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == current ? 30 : 6,
            height: 5,
            decoration: BoxDecoration(
              color: i == current
                  ? AppColors.accent
                  : i < current
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.surface2,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
