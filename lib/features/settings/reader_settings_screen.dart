import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';

/// Global reader defaults — manga and novel. These are the same
/// [ReaderPrefs] keys the in-reader settings sheets write; the manga
/// reader's per-series overrides (Direction/Fit chips there) sit on TOP of
/// whatever's set here and win when present, so this screen only ever
/// changes what an unmodified title falls back to.
///
/// Deliberately built from the SAME row language as the rest of Settings
/// (Playback, Interface…): compact rows showing the current value on the
/// right, tap to open a small picker — not the in-reader sheet's inline
/// segmented controls, which read as a heavy wall of pills on a full screen.
class ReaderSettingsScreen extends StatefulWidget {
  const ReaderSettingsScreen({super.key});

  @override
  State<ReaderSettingsScreen> createState() => _ReaderSettingsScreenState();
}

class _ReaderSettingsScreenState extends State<ReaderSettingsScreen> {
  ReaderPrefs get _prefs => sl<ReaderPrefs>();

  static const List<(String, String)> _directionOptions = [
    ('ltr', 'Left to right'),
    ('rtl', 'Right to left'),
    ('vertical', 'Vertical'),
  ];
  static const List<(String, String)> _fitOptions = [
    ('contain', 'Contain'),
    ('width', 'Width'),
    ('height', 'Height'),
    ('original', 'Original'),
    ('smart', 'Smart'),
  ];
  static const List<(String, String)> _backgroundOptions = [
    ('black', 'Black'),
    ('white', 'White'),
    ('gray', 'Gray'),
    ('system', 'Theme'),
  ];
  static const List<(String, String)> _filterOptions = [
    ('none', 'None'),
    ('grayscale', 'Grayscale'),
    ('invert', 'Invert'),
    ('sepia', 'Sepia'),
  ];
  static const List<(String, String)> _orientationOptions = [
    ('system', 'System'),
    ('portrait', 'Portrait'),
    ('landscape', 'Landscape'),
  ];
  static const List<(String, String)> _fontOptions = [
    ('inter', 'Inter'),
    ('serif', 'Serif'),
    ('system', 'System'),
  ];
  static const List<(String, String)> _textDirectionOptions = [
    ('auto', 'Auto'),
    ('ltr', 'Left to right'),
    ('rtl', 'Right to left'),
  ];
  static const List<(String, String)> _themeOptions = [
    ('dark', 'Dark'),
    ('black', 'Black'),
    ('sepia', 'Sepia'),
    ('gray', 'Gray'),
    ('paper', 'Paper'),
  ];

  String _labelOf(List<(String, String)> options, String value) {
    for (final (v, l) in options) {
      if (v == value) return l;
    }
    return value;
  }

  /// A row that shows its current value on the right and opens a small
  /// option-picker sheet on tap — the app-wide Settings pattern (mirrors
  /// `_pickSearchLayout` in settings_screen.dart), so this screen reads like
  /// every other Settings sub-page rather than a wall of segmented pills.
  Widget _pickerRow({
    required IconData icon,
    required String title,
    required List<(String, String)> options,
    required String current,
    required Future<void> Function(String) onPicked,
  }) {
    return SettingsTile(
      icon: icon,
      title: title,
      onTap: () => _openPicker(title, options, current, onPicked),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _labelOf(options, current),
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(width: 6),
          const Icon(
            Icons.chevron_right_rounded,
            color: AppColors.textTertiary,
            size: 20,
          ),
        ],
      ),
    );
  }

  Future<void> _openPicker(
    String title,
    List<(String, String)> options,
    String current,
    Future<void> Function(String) onPicked,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title, style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            for (final (v, l) in options)
              ListTile(
                title: Text(l, style: AppText.body),
                trailing: v == current
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await onPicked(picked);
    if (mounted) setState(() {});
  }

  /// A boolean row — same shape as `PlaybackSettingsScreen._toggleRow`.
  Widget _toggleRow({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: null,
      onTap: () => onChanged(!value),
      trailing: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.accent,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// A labelled slider row — same shape as
  /// `PlaybackSettingsScreen._megaSkipDurationRow`: holds the value locally
  /// while dragging and persists once on release.
  Widget _sliderRow({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String Function(double) format,
    required Future<void> Function(double) onChangeEnd,
  }) {
    double val = value.clamp(min, max);
    return StatefulBuilder(
      builder: (context, setLocal) => Padding(
        padding: const EdgeInsets.fromLTRB(15, 10, 15, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.textSecondary, size: 20),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                ),
                Text(
                  format(val),
                  style: AppText.body.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accent,
                thumbColor: AppColors.accent,
                inactiveTrackColor: AppColors.textSecondary.withValues(
                  alpha: 0.3,
                ),
                overlayColor: AppColors.accent.withValues(alpha: 0.2),
                trackHeight: 3,
              ),
              child: Slider(
                min: min,
                max: max,
                divisions: divisions,
                value: val,
                label: format(val),
                onChanged: (v) => setLocal(() => val = v),
                onChangeEnd: (v) async {
                  await onChangeEnd(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Reader'),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          const SettingsSectionLabel('Manga', first: true),
          SettingsCard(
            children: [
              _pickerRow(
                icon: Icons.swap_horiz_rounded,
                title: 'Reading mode',
                options: _directionOptions,
                current: prefs.direction,
                onPicked: prefs.setDirection,
              ),
              _pickerRow(
                icon: Icons.fit_screen_outlined,
                title: 'Fit',
                options: _fitOptions,
                current: prefs.fitMode,
                onPicked: prefs.setFitMode,
              ),
              _pickerRow(
                icon: Icons.format_paint_outlined,
                title: 'Background',
                options: _backgroundOptions,
                current: prefs.mangaBackground,
                onPicked: prefs.setMangaBackground,
              ),
              _pickerRow(
                icon: Icons.filter_b_and_w_rounded,
                title: 'Colour filter',
                options: _filterOptions,
                current: prefs.colorFilter,
                onPicked: prefs.setColorFilter,
              ),
              _pickerRow(
                icon: Icons.screen_rotation_outlined,
                title: 'Orientation lock',
                options: _orientationOptions,
                current: prefs.orientation,
                onPicked: prefs.setOrientation,
              ),
              _toggleRow(
                icon: Icons.vertical_split_rounded,
                title: 'Double-page (landscape)',
                subtitle: 'Pair facing pages in a landscape spread',
                value: prefs.doublePageLandscape,
                onChanged: (v) async {
                  await prefs.setDoublePageLandscape(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.crop_outlined,
                title: 'Crop borders',
                subtitle: 'Trim near-uniform edge margins from a page',
                value: prefs.cropBorders,
                onChanged: (v) async {
                  await prefs.setCropBorders(v);
                  if (mounted) setState(() {});
                },
              ),
              _sliderRow(
                icon: Icons.layers_outlined,
                title: 'Preload pages',
                value: prefs.preloadCount.toDouble(),
                min: 1,
                max: 8,
                divisions: 7,
                format: (v) => '${v.round()}',
                onChangeEnd: (v) => prefs.setPreloadCount(v.round()),
              ),
              _toggleRow(
                icon: Icons.screen_lock_portrait_outlined,
                title: 'Keep screen on',
                value: prefs.keepScreenOn,
                onChanged: (v) async {
                  await prefs.setKeepScreenOn(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          const SettingsSectionLabel('Novel'),
          SettingsCard(
            children: [
              _pickerRow(
                icon: Icons.font_download_outlined,
                title: 'Font',
                options: _fontOptions,
                current: prefs.fontFamily,
                onPicked: prefs.setFontFamily,
              ),
              _pickerRow(
                icon: Icons.style_outlined,
                title: 'Theme',
                options: _themeOptions,
                current: prefs.theme,
                onPicked: prefs.setTheme,
              ),
              _sliderRow(
                icon: Icons.format_size_rounded,
                title: 'Font size',
                value: prefs.fontSize,
                min: 12,
                max: 28,
                format: (v) => v.round().toString(),
                onChangeEnd: prefs.setFontSize,
              ),
              _sliderRow(
                icon: Icons.format_line_spacing_rounded,
                title: 'Line height',
                value: prefs.lineHeight,
                min: 1.2,
                max: 2.4,
                format: (v) => v.toStringAsFixed(1),
                onChangeEnd: prefs.setLineHeight,
              ),
              _sliderRow(
                icon: Icons.format_indent_increase_rounded,
                title: 'Margin',
                value: prefs.marginWidth,
                min: 0,
                max: 48,
                format: (v) => '${v.round()}',
                onChangeEnd: prefs.setMarginWidth,
              ),
              _toggleRow(
                icon: Icons.format_align_justify_rounded,
                title: 'Justify text',
                value: prefs.textAlignJustify,
                onChanged: (v) async {
                  await prefs.setTextAlignJustify(v);
                  if (mounted) setState(() {});
                },
              ),
              _pickerRow(
                icon: Icons.format_textdirection_r_to_l_rounded,
                title: 'Text direction',
                options: _textDirectionOptions,
                current: prefs.textDirection,
                onPicked: prefs.setTextDirection,
              ),
              _sliderRow(
                icon: Icons.view_stream_outlined,
                title: 'Paragraph spacing',
                value: prefs.paragraphSpacing,
                min: 0,
                max: 24,
                format: (v) => '${v.round()}',
                onChangeEnd: prefs.setParagraphSpacing,
              ),
              _toggleRow(
                icon: Icons.auto_stories_outlined,
                title: 'Paginated',
                subtitle: 'Book-style pages instead of a continuous scroll',
                value: prefs.novelPaginated,
                onChanged: (v) async {
                  await prefs.setNovelPaginated(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.screen_lock_portrait_outlined,
                title: 'Keep screen on',
                value: prefs.keepScreenOn,
                onChanged: (v) async {
                  await prefs.setKeepScreenOn(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
