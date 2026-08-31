import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../../core/ui/settings_widgets.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../core/app_icon/app_icon_service.dart';
import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/theme/theme_controller.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/animation_prefs.dart';

/// Dedicated Appearance page (Aniyomi-style): accent colour as preview cards
/// (+ a Custom colour picker), a pure-black AMOLED toggle, and the Home banner
/// animation style. Every option defaults to the current look, so an untouched
/// install is unchanged.
class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({super.key});

  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  /// Android 12+ only. Resolved once; the row stays hidden everywhere else
  /// rather than showing a switch that couldn't do anything.
  bool _wallpaperSupported = false;

  @override
  void initState() {
    super.initState();
    ThemeController.supported().then((ok) {
      if (mounted && ok) setState(() => _wallpaperSupported = true);
    });
  }

  bool get _accentIsCustom => !ThemeController.accentPresets.any(
    (p) => p.$2.toARGB32() == AppColors.accent.toARGB32(),
  );

  Future<void> _pickCustom() async {
    var temp = AppColors.accent;
    final result = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.customColour, style: AppText.headline),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: temp,
            onColorChanged: (c) => temp = c,
            enableAlpha: false,
            displayThumbColor: true,
            paletteType: PaletteType.hueWheel,
            labelTypes: const [],
            pickerAreaBorderRadius: BorderRadius.circular(12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              context.l10n.cancel,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, temp),
            child: Text(context.l10n.apply, style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (result != null) {
      await ThemeController.setAccent(result);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = ThemeController.accentPresets;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.appearance),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        children: [
          // ── Accent colour ─────────────────────────────────────────────────
          // The swatch strip stays exactly as it was, and stays first.
          SettingsSectionLabel(context.l10n.accentColour, first: true),
          _blurb(context.l10n.accentColourBlurb),
          Opacity(
            // Dimmed while the wallpaper is choosing — the swatches still work,
            // and tapping one takes you back to picking by hand.
            opacity: ThemeController.materialYou ? 0.4 : 1,
            child: SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                // Align with SettingsCard's margin so the strip lines up with
                // the cards below it.
                padding: const EdgeInsets.symmetric(horizontal: 16),
                clipBehavior: Clip.none,
                itemCount: presets.length + 1,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  if (i == presets.length) {
                    return _CustomCard(
                      selected: _accentIsCustom,
                      currentColor: AppColors.accent,
                      onTap: () {
                        if (_blockedByMaterialYou()) return;
                        _pickCustom();
                      },
                    );
                  }
                  final (name, color) = presets[i];
                  return _AccentCard(
                    name: name,
                    color: color,
                    selected:
                        !_accentIsCustom &&
                        AppColors.accent.toARGB32() == color.toARGB32(),
                    isDefault: ThemeController.isDefault(color),
                    onTap: () async {
                      if (_blockedByMaterialYou()) return;
                      await ThemeController.setAccent(color);
                      if (mounted) setState(() {});
                    },
                  );
                },
              ),
            ),
          ),
          // ── Theme ─────────────────────────────────────────────────────────
          SettingsSectionLabel(context.l10n.theme),
          SettingsCard(
            children: [
              if (_wallpaperSupported)
                _switchTile(
                  icon: Icons.palette_outlined,
                  title: context.l10n.materialYou,
                  // Doubles as the hint that the strip above still works.
                  subtitle: context.l10n.coloursFromYourWallpaper,
                  value: ThemeController.materialYou,
                  onChanged: ThemeController.setMaterialYou,
                ),
              _switchTile(
                icon: Icons.dark_mode_outlined,
                title: context.l10n.pureBlackBackground,
                subtitle: context.l10n.trueBlackForOLED,
                value: ThemeController.amoled,
                onChanged: ThemeController.setAmoled,
              ),
            ],
          ),

          // ── Display ───────────────────────────────────────────────────────
          SettingsSectionLabel(context.l10n.display),
          SettingsCard(
            children: [
              _switchTile(
                icon: Icons.sell_outlined,
                title: context.l10n.posterBadges,
                subtitle: context.l10n.qualityAndSubDubBadges,
                value: sl<PlaybackPrefs>().qualityBadges,
                onChanged: sl<PlaybackPrefs>().setQualityBadges,
              ),
              _switchTile(
                icon: Icons.auto_awesome_motion_outlined,
                title: context.l10n.animateLists,
                subtitle: context.l10n.cardsFadeInAsYouScroll,
                value: AnimationPrefs.listAnimations,
                onChanged: AnimationPrefs.setListAnimations,
              ),
              // Only meaningful while the animation is on.
              if (AnimationPrefs.listAnimations)
                SettingsTile(
                  icon: Icons.animation_outlined,
                  title: context.l10n.animationStyle,
                  subtitle: _animStyleBlurb(context),
                  trailing: Text(_animStyleName(context), style: AppText.caption),
                  onTap: _pickAnimStyle,
                ),
            ],
          ),

          // ── App icon ──────────────────────────────────────────────────────
          // Android-only: iOS has an unrelated API and TV has no icon picker.
          if (_icons.supported) ...[
            SettingsSectionLabel(context.l10n.appIcon),
            _blurb(context.l10n.appIconBlurb),
            const SizedBox(height: 10),
            _iconPicker(),
          ],
        ],
      ),
    );
  }

  /// True when the wallpaper is choosing the accent, so a swatch tap can't
  /// apply. Says so rather than doing nothing — the swatches are dimmed, but a
  /// dim control that swallows taps is still confusing.
  bool _blockedByMaterialYou() {
    if (!ThemeController.materialYou) return false;
    // FToast, matching the shell's exit toast — the app doesn't use SnackBars.
    (FToast()..init(context)).showToast(
      gravity: ToastGravity.BOTTOM,
      toastDuration: const Duration(seconds: 2),
      child: Container(
        margin: const EdgeInsets.only(bottom: 40),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xF01C1C1E),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          context.l10n.turnOffMaterialYouToPickAColourYourself,
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
    return true;
  }

  /// Section description under a [SettingsSectionLabel], indented to match it.
  Widget _blurb(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 0, 22, 10),
    child: Text(text, style: AppText.caption),
  );

  /// A [SettingsTile] with a switch. The whole row toggles, which is how the
  /// rest of Settings behaves — the switch alone was a small target.
  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
  }) {
    Future<void> flip(bool v) async {
      await onChanged(v);
      if (mounted) setState(() {});
    }

    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () => flip(!value),
      trailing: Switch.adaptive(
        value: value,
        activeThumbColor: AppColors.accent,
        onChanged: flip,
      ),
    );
  }

  static List<(ListAnimStyle, String, String)> _animStyles(BuildContext context) => [
    (ListAnimStyle.rise, context.l10n.animRise, context.l10n.animRiseDesc),
    (ListAnimStyle.fade, context.l10n.animFade, context.l10n.animFadeDesc),
    (ListAnimStyle.zoom, context.l10n.animZoom, context.l10n.animZoomDesc),
  ];

  (ListAnimStyle, String, String) _animStyle(BuildContext context) => _animStyles(context).firstWhere(
    (o) => o.$1 == AnimationPrefs.style,
    orElse: () => _animStyles(context).first,
  );
  String _animStyleName(BuildContext context) => _animStyle(context).$2;
  String _animStyleBlurb(BuildContext context) => _animStyle(context).$3;

  /// Style picker. Was three rows always on the page; a sheet keeps the screen
  /// short and matches how the other settings pickers behave.
  Future<void> _pickAnimStyle() async {
    final picked = await showModalBottomSheet<ListAnimStyle>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [Text(context.l10n.animationStyle, style: AppText.headline)],
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            for (final (style, name, blurb) in _animStyles(context))
              ListTile(
                onTap: () => Navigator.pop(ctx, style),
                title: Text(
                  name,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                ),
                subtitle: Text(blurb, style: AppText.caption),
                trailing: AnimationPrefs.style == style
                    ? Icon(Icons.check, color: AppColors.accent)
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await AnimationPrefs.setStyle(picked);
    if (mounted) setState(() {});
  }

  final _icons = AppIconService();

  /// Row of selectable launcher icons. Confirms before switching, because
  /// Android tears the task down when the live launcher component is disabled.
  Widget _iconPicker() {
    final current = _icons.selectedId;
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

  Future<void> _pickIcon(AppIconOption o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.useTheIcon(o.label), style: AppText.title),
        content: Text(
          context.l10n.useTheIconBody,
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.change, style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _icons.select(o.id);
    if (mounted) setState(() {});
  }
}

/// A single accent option, rendered as a mini app preview in that colour.
class _AccentCard extends StatelessWidget {
  const _AccentCard({
    required this.name,
    required this.color,
    required this.selected,
    required this.isDefault,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final bool isDefault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 98,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? color : AppColors.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 58, child: _preview(color, selected)),
              const SizedBox(height: 8),
              Text(
                isDefault ? context.l10n.defaultLabel : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Custom" option — opens a colour wheel. Preview shows a rainbow sweep,
/// or the current custom colour when one is active.
class _CustomCard extends StatelessWidget {
  const _CustomCard({
    required this.selected,
    required this.currentColor,
    required this.onTap,
  });
  final bool selected;
  final Color currentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 98,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? currentColor : AppColors.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 58,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const SweepGradient(
                      colors: [
                        Color(0xFFFF4D57),
                        Color(0xFFFFB020),
                        Color(0xFF32D583),
                        Color(0xFF3DD6D0),
                        Color(0xFF4D8DFF),
                        Color(0xFF9B6DFF),
                        Color(0xFFFF5FA2),
                        Color(0xFFFF4D57),
                      ],
                    ),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        selected ? Icons.check_rounded : Icons.colorize_rounded,
                        color: AppColors.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.custom,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _preview(Color color, bool selected) => Stack(
  children: [
    Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Container(
            height: 5,
            width: 34,
            decoration: BoxDecoration(
              color: AppColors.textTertiary,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Row(
            children: [
              Container(
                width: 40,
                height: 13,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.22),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          Container(
            height: 4,
            width: 58,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ),
    ),
    if (selected)
      Positioned(
        top: 3,
        right: 3,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.surface2, width: 2),
          ),
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 11),
        ),
      ),
  ],
);

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
