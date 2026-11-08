import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../../core/ui/settings_widgets.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_toast.dart';
import '../../core/theme/app_font_prefs.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/animation_prefs.dart';
import '../../core/ui/detail_prefs.dart';

/// Theme and colour: accent as preview cards (+ a Custom colour picker), the
/// pure-black AMOLED toggle, the adaptive poster tint, the app font and how
/// lists animate.
///
/// The app icon, splash and Home banner pickers used to live at the bottom of
/// this page, below four other sections. They answer a different question —
/// which face the app wears — so they have their own page now
/// ([AppFaceScreen]); nothing about what they do changed in the move.
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
      if (mounted) setState(() => _wallpaperSupported = ok);
    });
  }

  bool get _accentIsCustom => !ThemeController.accentPresets.any(
    (p) => p.$2.toARGB32() == AppColors.accent.toARGB32(),
  );

  Future<void> _pickCustom() async {
    final result = await _showColourPicker(
      title: context.l10n.customColour,
      initial: AppColors.accent,
    );
    if (result != null) {
      await _updateProfileTheme(accentColor: result.toARGB32());
    }
  }

  /// The accent colour wheel. (The background has its own picker below —
  /// the wheel's brightness track cannot be capped.)
  Future<Color?> _showColourPicker({
    required String title,
    required Color initial,
  }) {
    var temp = initial;
    return showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title, style: AppText.headline),
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
            child: Text(
              context.l10n.apply,
              style: TextStyle(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }

  /// Background picker: sliders instead of the wheel, whose brightness track
  /// paints the whole range no matter what. Here the slider simply ends at
  /// [ThemeController.maxBackgroundValue] — the top IS the readable maximum,
  /// so nothing the picker offers gets silently darkened afterwards.
  Future<Color?> _showBackgroundPicker() {
    var hsv = HSVColor.fromColor(AppColors.bg);
    if (hsv.value > ThemeController.maxBackgroundValue) {
      hsv = hsv.withValue(ThemeController.maxBackgroundValue);
    }

    String hueName(double h) => const [
      'Red',
      'Orange',
      'Yellow',
      'Lime',
      'Green',
      'Teal',
      'Cyan',
      'Azure',
      'Blue',
      'Indigo',
      'Violet',
      'Magenta',
    ][((h % 360) / 30).floor() % 12];
    String satName(double s) => s < 0.15
        ? 'Muted'
        : s < 0.45
        ? 'Soft'
        : s < 0.75
        ? 'Rich'
        : 'Full';
    String brightName(double v) => v < 0.14
        ? 'Dim'
        : v < 0.28
        ? 'Soft'
        : v < 0.4
        ? 'Deep'
        : 'Max';

    return showDialog<Color>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final colour = hsv.toColor();

          Widget trackRow(
            String label,
            String valueLabel,
            List<Color> gradient,
            double value,
            double max,
            HSVColor Function(double) apply,
          ) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    label,
                    style: AppText.body.copyWith(
                      color: const Color(0xFFE9E9EF),
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                  ),
                  const Spacer(),
                  Text(valueLabel, style: AppText.caption),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      child: Container(
                        height: 12,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(colors: gradient),
                          border: Border.all(color: AppColors.hairline),
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 12,
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 11,
                          elevation: 5,
                        ),
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: value,
                        max: max,
                        onChanged: (v) => setDialogState(() => hsv = apply(v)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 17),
            ],
          );

          return Dialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Background colour', style: AppText.headline),
                    const SizedBox(height: 16),
                    // A Stack, not `color` + `gradient` in one BoxDecoration:
                    // when a gradient is present Flutter ignores the colour, so
                    // the preview would stay the dialog's surface colour.
                    Container(
                      height: 88,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: colour,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppColors.hairline),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.centerRight,
                                  colors: [
                                    Colors.white.withValues(alpha: 0.14),
                                    Colors.transparent,
                                  ],
                                  stops: const [0, 0.42],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 10,
                            bottom: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${hueName(hsv.hue)} · preview',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    trackRow(
                      'Hue',
                      hueName(hsv.hue),
                      const [
                        Color(0xFFF43F5E),
                        Color(0xFFF59E0B),
                        Color(0xFF84CC16),
                        Color(0xFF10B981),
                        Color(0xFF06B6D4),
                        Color(0xFF3B82F6),
                        Color(0xFF8B5CF6),
                        Color(0xFFEC4899),
                        Color(0xFFF43F5E),
                      ],
                      hsv.hue,
                      360,
                      (v) => hsv.withHue(v),
                    ),
                    trackRow(
                      'Saturation',
                      satName(hsv.saturation),
                      [
                        HSVColor.fromAHSV(1, hsv.hue, 0, hsv.value).toColor(),
                        HSVColor.fromAHSV(1, hsv.hue, 1, hsv.value).toColor(),
                      ],
                      hsv.saturation,
                      1,
                      (v) => hsv.withSaturation(v),
                    ),
                    trackRow(
                      'Brightness',
                      brightName(hsv.value),
                      [
                        const Color(0xFF050507),
                        Color.lerp(Colors.black, colour, 0.55)!,
                        colour,
                      ],
                      hsv.value,
                      ThemeController.maxBackgroundValue,
                      (v) => hsv.withValue(v),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () =>
                              Navigator.pop(ctx, AppColors.defaultBg),
                          child: Text(
                            'Reset',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(
                            context.l10n.cancel,
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 4),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 22,
                              vertical: 11,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx, hsv.toColor()),
                          child: Text(context.l10n.apply),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickBackground() async {
    if (_blockedByMaterialYou()) return;
    if (ThemeController.amoled) {
      showAppToast(context, 'Turn off Pure black background first');
      return;
    }
    final result = await _showBackgroundPicker();
    if (result == null) return;
    await ThemeController.setBackgroundColour(result);
    if (mounted) setState(() {});
  }

  Future<void> _updateProfileTheme({
    int? accentColor,
    bool? materialYou,
    bool? amoled,
  }) async {
    final profiles = sl<ViewerProfileStore>();
    await profiles.updateTheme(
      profiles.activeId,
      accentColor: accentColor,
      materialYou: materialYou,
      amoled: amoled,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final presets = ThemeController.accentPresets;
    return Scaffold(
      backgroundColor: AppColors.bg,
      // Matches the row that opens it in Interface → Look.
      appBar: settingsAppBar('Theme & colour'),
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
                      await _updateProfileTheme(accentColor: color.toARGB32());
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
                  onChanged: (value) => _updateProfileTheme(materialYou: value),
                ),
              _switchTile(
                icon: Icons.dark_mode_outlined,
                title: context.l10n.pureBlackBackground,
                subtitle: context.l10n.trueBlackForOLED,
                value: ThemeController.amoled,
                onChanged: (value) => _updateProfileTheme(amoled: value),
              ),
              SettingsTile(
                icon: Icons.format_color_fill_rounded,
                title: 'Background colour',
                subtitle:
                    'Behind every screen; Home and Detail use the adaptive tint while it is on. Kept dark for readable text',
                subtitleMaxLines: null,
                trailing: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.hairline),
                  ),
                ),
                onTap: _pickBackground,
              ),
              _switchTile(
                icon: Icons.auto_awesome_outlined,
                title: 'Adaptive colour',
                subtitle:
                    'Tints the background of Home and Detail from the poster colour',
                value: ThemeController.adaptiveColour,
                onChanged: ThemeController.setAdaptiveColour,
                subtitleMaxLines: null,
              ),
              _switchTile(
                icon: Icons.title_rounded,
                title: 'Title artwork',
                subtitle:
                    'Show the official title logo instead of plain text on Detail',
                value: ThemeController.titleLogo,
                onChanged: ThemeController.setTitleLogo,
                subtitleMaxLines: null,
              ),
            ],
          ),

          // ── Font ──────────────────────────────────────────────────────────
          SettingsSectionLabel('Font'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.text_fields_rounded,
                title: 'App font',
                subtitle: 'Everything in the app is drawn in this',
                trailing: Text(AppFontPrefs.label, style: AppText.caption),
                onTap: _pickFont,
              ),
            ],
          ),

          // ── Display ───────────────────────────────────────────────────────
          SettingsSectionLabel(context.l10n.display),
          SettingsCard(
            children: [
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
                  trailing: Text(
                    _animStyleName(context),
                    style: AppText.caption,
                  ),
                  onTap: _pickAnimStyle,
                ),
            ],
          ),
          // ── Behaviour ─────────────────────────────────────────────────────
          SettingsSectionLabel('Behaviour'),
          SettingsCard(
            children: [
              _switchTile(
                icon: Icons.swap_vert_rounded,
                title: 'Reverse episode list always on',
                subtitle:
                    'Every detail screen opens newest-first; the list button still flips it for that visit',
                value: DetailPrefs.reverseEpisodesDefault,
                onChanged: DetailPrefs.setReverseEpisodesDefault,
                subtitleMaxLines: null,
              ),
            ],
          ),
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

  /// Every choice previewed in its OWN face — a list of names all set in the
  /// current font tells you nothing about what you are picking.
  Future<void> _pickFont() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [Text('App font', style: AppText.headline)],
                ),
              ),
              const Divider(color: AppColors.hairline, height: 1),
              for (final f in AppFontPrefs.fonts)
                ListTile(
                  onTap: () => Navigator.pop(ctx, f.family),
                  // Previewed in its OWN face — but only once it is on the
                  // device. Naming an unfetched font in a family Flutter has
                  // never loaded just draws the platform default, so the row
                  // would advertise a face you aren't going to get.
                  title: Text(
                    f.label,
                    style: AppText.body.copyWith(
                      fontFamily: f.bundled ? f.family : null,
                      color: AppColors.textPrimary,
                      fontSize: 16,
                    ),
                  ),
                  subtitle: Text(
                    AppFontPrefs.isSystem(f.family)
                        ? "Your phone's default font"
                        : f.bundled
                        ? 'Watch anime, movies and series'
                        : 'Downloads on first use',
                    style: AppText.caption.copyWith(
                      fontFamily: f.bundled ? f.family : null,
                    ),
                  ),
                  trailing: f.family == AppFontPrefs.family
                      ? Icon(Icons.check, color: AppColors.accent)
                      : (f.bundled || AppFontPrefs.isSystem(f.family)
                            ? null
                            : Icon(
                                Icons.download_outlined,
                                size: 18,
                                color: AppColors.textTertiary,
                              )),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted || picked == AppFontPrefs.family) return;
    // Fetch BEFORE saving. Saving first would restart the app into a family
    // Flutter has never loaded, which draws the platform default and reads as
    // the setting having been ignored.
    if (!AppFontPrefs.isBundled(picked)) {
      final ok = await AppFontPrefs.ensure(picked);
      if (!mounted) return;
      if (!ok) {
        showAppToast(context, "Couldn't download that font — still online?");
        return;
      }
    }
    await AppFontPrefs.setFamily(picked);
    if (mounted) setState(() {});
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
    int? subtitleMaxLines = 1,
  }) {
    Future<void> flip(bool v) async {
      await onChanged(v);
      if (mounted) setState(() {});
    }

    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: subtitleMaxLines,
      onTap: () => flip(!value),
      trailing: Switch.adaptive(
        value: value,
        activeThumbColor: AppColors.accent,
        onChanged: flip,
      ),
    );
  }

  static List<(ListAnimStyle, String, String)> _animStyles(
    BuildContext context,
  ) => [
    (ListAnimStyle.rise, context.l10n.animRise, context.l10n.animRiseDesc),
    (ListAnimStyle.fade, context.l10n.animFade, context.l10n.animFadeDesc),
    (ListAnimStyle.zoom, context.l10n.animZoom, context.l10n.animZoomDesc),
  ];

  (ListAnimStyle, String, String) _animStyle(BuildContext context) =>
      _animStyles(context).firstWhere(
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
                children: [
                  Text(context.l10n.animationStyle, style: AppText.headline),
                ],
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
