import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../sources/providers_hub_screen.dart';
import 'onboarding_screen_tv.dart';
import '../../l10n/l10n.dart';

/// First-run flag, stored in the shared 'app_prefs' Hive box (opened during
/// [initDependencies]). True once the user has completed onboarding.
bool isOnboarded() =>
    Hive.box(ActiveSourceCubit.boxName).get('onboarded', defaultValue: false)
        as bool;

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
  late final Animation<double> _glow =
      CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.55, curve: Curves.easeOut));
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: const Interval(0.12, 0.5, curve: Curves.easeOut));
  late final Animation<double> _reveal =
      CurvedAnimation(parent: _c, curve: const Interval(0.12, 1.0, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
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
// Onboarding — first launch. The app ships with NO sources installed; this
// screen just explains that and points the user at Providers to add their
// own repository, then hands off to the app via [onDone]. Three swipeable
// pages (brand → how sources work → the two hand-off actions), all purely
// presentational — no network call or install anywhere on this screen.
// ─────────────────────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  /// Called once setup completes (or is skipped) — the boot gate then shows
  /// the app shell.
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 3;

  final _controller = PageController();
  double _page = 0;

  @override
  void initState() {
    super.initState();
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

  /// Marks onboarding done, hands off to the app, then opens Providers so the
  /// user lands right where they add a repository. No network call, no
  /// install — the app just navigates.
  Future<void> _addSourcesNow() async {
    await _markOnboarded();
    if (!mounted) return;
    widget.onDone();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProvidersHubScreen()),
    );
  }

  Future<void> _later() async {
    await _markOnboarded();
    if (mounted) widget.onDone();
  }

  void _next() => _controller.nextPage(
    duration: const Duration(milliseconds: 320),
    curve: Curves.easeOutCubic,
  );

  /// Eases a page in/out and gives it a touch of depth as it scrolls past —
  /// tied to the live scroll position (no spring/bounce). `delta` is how
  /// many pages this page currently sits from the controller's position, and
  /// is handed to the page itself so its hero art and its text can drift at
  /// their own, slightly different rates (parallax).
  Widget _pageShell(int index, Widget Function(double delta) builder) {
    final delta = (_page - index).clamp(-1.0, 1.0);
    final fade = 1 - Curves.easeOut.transform(delta.abs()) * 0.55;
    return Opacity(
      opacity: fade,
      child: Transform.translate(
        offset: Offset(0, delta * 14),
        child: builder(delta),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return OnboardingScreenTv(onDone: widget.onDone);
    final onLastPage = _page > _pageCount - 1.5;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 20, 4),
              child: SizedBox(
                height: 40,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: onLastPage ? 0 : 1,
                    child: IgnorePointer(
                      ignoring: onLastPage,
                      child: TextButton(
                        onPressed: _later,
                        child: Text(
                          context.l10n.skip,
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                children: [
                  _pageShell(0, (d) => _BrandPage(delta: d)),
                  _pageShell(1, (d) => _HowItWorksPage(delta: d)),
                  _pageShell(
                    2,
                    (d) => _GetGoingPage(
                      delta: d,
                      onAddSourcesNow: _addSourcesNow,
                      onLater: _later,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
              child: Row(
                children: [
                  _PageDots(page: _page, count: _pageCount),
                  const Spacer(),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: onLastPage ? 0 : 1,
                    child: IgnorePointer(
                      ignoring: onLastPage,
                      child: _NextButton(onTap: _next),
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

/// Centers a page's content vertically, but lets it scroll on short screens
/// instead of overflowing.
class _ScrollablePage extends StatelessWidget {
  const _ScrollablePage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// Page 1 — the brand moment. The logo mark and wordmark, stacked, on the
/// app's usual dark background with the same soft accent glow the splash
/// screen uses — then a warm one-line welcome. The hero art drifts a touch
/// slower than the welcome text as the page scrolls (parallax via [delta]).
class _BrandPage extends StatelessWidget {
  const _BrandPage({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    return _ScrollablePage(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: Transform.translate(
              offset: Offset(delta * 10, 0),
              child: Container(
                width: 260,
                height: 260,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppColors.accent.withValues(alpha: 0.14),
                      AppColors.accent.withValues(alpha: 0.04),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/icon/logo_mark.png',
                      width: 92,
                      height: 92,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 16),
                    FractionallySizedBox(
                      widthFactor: 0.62,
                      child: Image.asset(
                        'assets/icon/wordmark.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 34),
          Transform.translate(
            offset: Offset(delta * 22, 0),
            child: Column(
              children: [
                Text(
                  context.l10n.goodToHaveYouHere,
                  style: AppText.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.onboardingIntro,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Page 2 — mechanics. The three ecosystems a repository can belong to, then
/// the four taps it takes to get from here to a working source. The
/// ecosystem row drifts a touch slower than the text above and below it as
/// the page scrolls (parallax via [delta]).
class _HowItWorksPage extends StatelessWidget {
  const _HowItWorksPage({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    return _ScrollablePage(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.translate(
            offset: Offset(delta * 22, 0),
            child: Column(
              children: [
                Text(
                  context.l10n.youChooseWhatsInside,
                  style: AppText.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  context.l10n.addTheSourcesYouWant,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          Transform.translate(
            offset: Offset(delta * 10, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _EcosystemTile(
                  icon: Icons.movie_filter_outlined,
                  label: context.l10n.modeStreaming,
                ),
                _EcosystemTile(icon: Icons.menu_book_outlined, label: context.l10n.modeManga),
                _EcosystemTile(
                  icon: Icons.auto_stories_outlined,
                  label: context.l10n.modeNovel,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Transform.translate(
            offset: Offset(delta * 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Step(number: 1, label: context.l10n.openProviders),
                _Step(number: 2, label: context.l10n.pickStreamingMangaOrNovels),
                _Step(number: 3, label: context.l10n.pasteInARepositoryLink),
                _Step(number: 4, label: context.l10n.browseAndGrab),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EcosystemTile extends StatelessWidget {
  const _EcosystemTile({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: AppColors.textSecondary, size: 26),
        ),
        const SizedBox(height: 9),
        Text(label, style: AppText.caption),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.label});

  final int number;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: AppText.caption.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Page 3 — the hand-off. Same two actions and same styling this screen
/// always had; only the surrounding page (and copy above them) is new. The
/// closing line drifts a touch as the page scrolls in (parallax via
/// [delta]); the buttons stay put once you land here, so they're always
/// easy to tap.
class _GetGoingPage extends StatelessWidget {
  const _GetGoingPage({
    required this.delta,
    required this.onAddSourcesNow,
    required this.onLater,
  });

  final double delta;
  final VoidCallback onAddSourcesNow;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    return _ScrollablePage(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.translate(
            offset: Offset(delta * 22, 0),
            child: Column(
              children: [
                Text(
                  context.l10n.readyWhenYouAre,
                  style: AppText.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.providersWaitingInSettings,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: onAddSourcesNow,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                context.l10n.addSourcesNow,
                style: AppText.button.copyWith(color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: onLater,
            child: Text(
              context.l10n.illDoItLater,
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small dot row — an accent pill for the active page, muted dots otherwise.
class _PageDots extends StatelessWidget {
  const _PageDots({required this.page, required this.count});

  final double page;
  final int count;

  @override
  Widget build(BuildContext context) {
    final activeIndex = page.round().clamp(0, count - 1);
    return Row(
      children: List.generate(count, (i) {
        final isActive = i == activeIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          margin: const EdgeInsets.only(right: 6),
          width: isActive ? 18 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: isActive ? AppColors.accent : AppColors.surface2,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

/// Circular next-page control — the only way forward on pages 1-2 besides
/// swiping.
class _NextButton extends StatelessWidget {
  const _NextButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface2,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Icon(
            Icons.arrow_forward_rounded,
            color: AppColors.accent,
            size: 22,
          ),
        ),
      ),
    );
  }
}
