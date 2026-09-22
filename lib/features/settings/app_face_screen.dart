import 'package:flutter/material.dart';

import '../onboarding/bankai_splash.dart';
import '../../core/app_icon/app_icon_service.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/banner_style.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/splash_style.dart';
import '../../l10n/l10n.dart';

/// The three pickers that decide what the app LOOKS like before you are even
/// in it: the launcher icon, the splash, and the Home banner.
///
/// Lifted wholesale out of the Appearance page, where they sat below accent
/// colour, theme, font and display toggles — four sections deep, on a page
/// whose subtitle could not mention them. Same pickers, same behaviour, same
/// stored ids; only the address changed.
class AppFaceScreen extends StatefulWidget {
  const AppFaceScreen({super.key});

  @override
  State<AppFaceScreen> createState() => _AppFaceScreenState();
}

class _AppFaceScreenState extends State<AppFaceScreen> {
  @override
  void initState() {
    super.initState();
    _reconcileIcon();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Icon, splash & banner'),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        children: [
          // ── App icon ──────────────────────────────────────────────────────
          // Android-only: iOS has an unrelated API and TV has no icon picker.
          if (_icons.supported) ...[
            SettingsSectionLabel(context.l10n.appIcon),
            _blurb(context.l10n.appIconBlurb),
            const SizedBox(height: 10),
            _iconPicker(),
          ],

          // ── Splash ────────────────────────────────────────────────────────
          // Every platform: this one is drawn by us, with no OS involvement.
          SettingsSectionLabel(context.l10n.splashStyle),
          _blurb(context.l10n.splashStyleBlurb),
          const SizedBox(height: 10),
          _splashPicker(),

          // ── Home banner ───────────────────────────────────────────────────
          // Phone only: the TV home draws its own banner and doesn't read this.
          if (!sl<AppMode>().isTv) ...[
            SettingsSectionLabel('Home banner'),
            _blurb('How the featured title shows on Home.'),
            const SizedBox(height: 10),
            _bannerPicker(),
          ],
        ],
      ),
    );
  }

  /// Section description under a [SettingsSectionLabel], indented to match it.
  Widget _blurb(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
    child: Text(text, style: AppText.caption.copyWith(height: 1.35)),
  );

  final _icons = AppIconService();

  /// What PackageManager actually has enabled, once [_reconcileIcon] has asked.
  /// Null until then, so the first frame falls back to the stored pref rather
  /// than flickering through "nothing selected".
  String? _iconActual;

  /// The stored preference can name a different icon than the one on the home
  /// screen — an interrupted switch, or an update that changed which alias
  /// ships enabled. Ask Android and correct the pref, so the tick here matches
  /// what the user is actually looking at.
  Future<void> _reconcileIcon() async {
    final id = await _icons.reconciledId();
    if (mounted && id != _iconActual) setState(() => _iconActual = id);
  }

  /// Row of selectable launcher icons. Confirms before switching, because
  /// Android tears the task down when the live launcher component is disabled.
  Widget _iconPicker() {
    final current = _iconActual ?? _icons.selectedId;
    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // Same inset as SettingsCard's margin, so the row lines up with the
        // cards and section labels above it.
        padding: const EdgeInsets.symmetric(horizontal: 16),
        clipBehavior: Clip.none,
        itemCount: AppIconService.options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final o = AppIconService.options[i];
          return _AppIconCard(
            option: o,
            selected: o.id == current,
            onTap: o.id == current ? null : () => _pickIcon(o),
          );
        },
      ),
    );
  }

  /// Row of splash animations, each card playing its own live preview — the
  /// choice only shows itself at launch, so a still would tell you nothing.
  ///
  /// No confirm dialog, unlike the icon picker: nothing is torn down, and the
  /// next launch simply plays the other one.
  Widget _splashPicker() {
    final current = SplashStyle.selectedId;
    return SizedBox(
      height: 112,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        clipBehavior: Clip.none,
        itemCount: SplashStyle.options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final o = SplashStyle.options[i];
          return _SplashCard(
            option: o,
            selected: o.id == current,
            onTap: o.id == current
                ? null
                : () async {
                    await SplashStyle.select(o.id);
                    if (mounted) setState(() {});
                  },
          );
        },
      ),
    );
  }

  /// Row of Home banners, each card drawing a miniature of the layout — this
  /// choice is about shape, so a list of names would say nothing.
  ///
  /// No confirm dialog: nothing is torn down and Home redraws on the way back.
  Widget _bannerPicker() {
    final current = BannerStyle.current.value;
    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        clipBehavior: Clip.none,
        itemCount: BannerStyle.options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final o = BannerStyle.options[i];
          return _BannerStyleCard(
            option: o,
            selected: o.id == current,
            onTap: o.id == current
                ? null
                : () async {
                    await BannerStyle.select(o.id);
                    if (mounted) setState(() {});
                  },
          );
        },
      ),
    );
  }

  Future<void> _pickIcon(AppIconOption o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.useTheIcon(o.label), style: AppText.title),
        content: Text(context.l10n.useTheIconBody, style: AppText.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              context.l10n.change,
              style: TextStyle(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _icons.select(o.id);
    if (mounted) setState(() {});
  }
}

/// A launcher-icon choice: preview, name, and a tick when it's the active one.
/// Mirrors [_AccentCard]'s shape so the two pickers read as one screen.
class _AppIconCard extends StatelessWidget {
  const _AppIconCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final AppIconOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 92,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? AppColors.accent : AppColors.hairline,
                  width: selected ? 2 : 1,
                ),
              ),
              padding: const EdgeInsets.all(3),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Image.asset(option.asset, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: selected ? AppColors.accent : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One splash choice, previewing itself on a loop.
///
/// A still frame would be useless here — the whole difference between the two
/// is motion, and the user only ever sees it at launch. So each card runs the
/// real animation, at the real timings, on a slow repeat.
class _SplashCard extends StatefulWidget {
  const _SplashCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final SplashStyleOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_SplashCard> createState() => _SplashCardState();
}

class _SplashCardState extends State<_SplashCard>
    with SingleTickerProviderStateMixin {
  // Real duration plus a pause, so the finished mark is readable between runs
  // instead of the loop reading as a flicker.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Maps the looping controller onto the animation, holding at the end.
  double get _t => (_c.value / 0.62).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 100,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: sel ? AppColors.accent : AppColors.hairline,
                  width: sel ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => widget.option.id == 'bankai'
                    ? Center(child: BankaiSplash(progress: _t, size: 72))
                    : Center(
                        child: Opacity(
                          opacity: _t.clamp(0.0, 1.0),
                          child: FractionallySizedBox(
                            widthFactor: 0.82,
                            child: Image.asset(
                              'assets/icon/wordmark.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: sel ? AppColors.accent : AppColors.textSecondary,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One Home-banner option, drawn as a miniature of the layout it picks.
class _BannerStyleCard extends StatelessWidget {
  const _BannerStyleCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final BannerStyleOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 100,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? AppColors.accent : AppColors.hairline,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Center(child: _preview()),
            ),
            const SizedBox(height: 8),
            Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: selected ? AppColors.accent : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            Text(
              option.blurb,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(
                fontSize: 9.5,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Art stand-in for all three: the same muted gradient, so what differs
  /// between the cards is the shape and nothing else.
  static const _art = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4A3A60), Color(0xFF1E2030)],
  );

  Widget _preview() {
    switch (option.id) {
      case BannerStyle.panelsId:
        return Transform.rotate(
          angle: -0.05,
          child: SizedBox(
            width: 58,
            height: 46,
            child: Row(
              // Stretch on both axes: a DecoratedBox with no child collapses
              // to nothing under a loose constraint, and the preview draws as
              // three lines instead of three panels.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 17, child: _pane()),
                const SizedBox(width: 3),
                Expanded(
                  flex: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _pane()),
                      const SizedBox(height: 3),
                      Expanded(child: _pane()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      default:
        return Container(
          width: 58,
          height: 46,
          decoration: BoxDecoration(
            gradient: _art,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.only(bottom: 7),
          child: Container(
            width: 22,
            height: 6,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
    }
  }

  Widget _pane() => Container(
    decoration: const BoxDecoration(gradient: _art),
    foregroundDecoration: BoxDecoration(
      border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1),
    ),
  );
}
