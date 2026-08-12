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
  static const List<(String, String)> _themeOptions = [
    ('dark', 'Dark'),
    ('black', 'Black'),
    ('sepia', 'Sepia'),
    ('gray', 'Gray'),
    ('paper', 'Paper'),
  ];

  String _labelFor(List<(String, String)> options, String value) => options
      .firstWhere((o) => o.$1 == value, orElse: () => (value, value))
      .$2;

  Future<T?> _pick<T>({
    required String title,
    required List<(T, String)> options,
    required T current,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
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
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.6,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final (value, label) in options)
                      ListTile(
                        onTap: () => Navigator.pop(ctx, value),
                        title: Text(
                          label,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        trailing: value == current
                            ? Icon(Icons.check, color: AppColors.accent)
                            : null,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickString({
    required String title,
    required List<(String, String)> options,
    required String current,
    required Future<void> Function(String) onPicked,
  }) async {
    final picked = await _pick<String>(
      title: title,
      options: options,
      current: current,
    );
    if (picked == null) return;
    await onPicked(picked);
    if (mounted) setState(() {});
  }

  /// A boolean row rendered as a [SwitchListTile]-shaped [SettingsTile] —
  /// same shape as `PlaybackSettingsScreen._toggleRow`.
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.textSecondary, size: 22),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: AppText.headline.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
                Text(
                  format(val),
                  style: AppText.headline.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
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
          const SettingsSectionLabel('Manga defaults', first: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.swap_horiz_rounded,
                title: 'Reading mode',
                subtitle: _labelFor(_directionOptions, prefs.direction),
                onTap: () => _pickString(
                  title: 'Reading mode',
                  options: _directionOptions,
                  current: prefs.direction,
                  onPicked: prefs.setDirection,
                ),
              ),
              SettingsTile(
                icon: Icons.fit_screen_outlined,
                title: 'Fit',
                subtitle: _labelFor(_fitOptions, prefs.fitMode),
                onTap: () => _pickString(
                  title: 'Fit',
                  options: _fitOptions,
                  current: prefs.fitMode,
                  onPicked: prefs.setFitMode,
                ),
              ),
              SettingsTile(
                icon: Icons.format_paint_outlined,
                title: 'Background',
                subtitle: _labelFor(_backgroundOptions, prefs.mangaBackground),
                onTap: () => _pickString(
                  title: 'Background',
                  options: _backgroundOptions,
                  current: prefs.mangaBackground,
                  onPicked: prefs.setMangaBackground,
                ),
              ),
              SettingsTile(
                icon: Icons.filter_b_and_w_rounded,
                title: 'Colour filter',
                subtitle: _labelFor(_filterOptions, prefs.colorFilter),
                onTap: () => _pickString(
                  title: 'Colour filter',
                  options: _filterOptions,
                  current: prefs.colorFilter,
                  onPicked: prefs.setColorFilter,
                ),
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
              SettingsTile(
                icon: Icons.screen_rotation_outlined,
                title: 'Orientation lock',
                subtitle: _labelFor(_orientationOptions, prefs.orientation),
                onTap: () => _pickString(
                  title: 'Orientation lock',
                  options: _orientationOptions,
                  current: prefs.orientation,
                  onPicked: prefs.setOrientation,
                ),
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
          const SettingsSectionLabel('Novel defaults'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.font_download_outlined,
                title: 'Font',
                subtitle: _labelFor(_fontOptions, prefs.fontFamily),
                onTap: () => _pickString(
                  title: 'Font',
                  options: _fontOptions,
                  current: prefs.fontFamily,
                  onPicked: prefs.setFontFamily,
                ),
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
              SettingsTile(
                icon: Icons.style_outlined,
                title: 'Theme',
                subtitle: _labelFor(_themeOptions, prefs.theme),
                onTap: () => _pickString(
                  title: 'Theme',
                  options: _themeOptions,
                  current: prefs.theme,
                  onPicked: prefs.setTheme,
                ),
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
