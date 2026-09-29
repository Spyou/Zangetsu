import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/nav_prefs.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/ui_strings.dart';
import '../shell/dock_icons.dart';
import '../shell/mode_bar.dart' show iconForMode;

/// Choose which tabs the bottom bar shows, and in what order.
///
/// Laid out like `PlayerControlsScreen` — a live miniature on top, then the
/// lists — for the same reason: editing a list of names and guessing what the
/// bar ends up looking like is the part that doesn't work.
class NavTabsScreen extends StatefulWidget {
  const NavTabsScreen({super.key});

  @override
  State<NavTabsScreen> createState() => _NavTabsScreenState();
}

class _NavTabsScreenState extends State<NavTabsScreen> {
  NavPrefs get _prefs => sl<NavPrefs>();

  late List<DockTab> _shown = List.of(_prefs.tabs);

  List<DockTab> get _hidden => [
    for (final t in DockTab.values)
      if (!_shown.contains(t)) t,
  ];

  bool get _canRemove => _shown.length > NavPrefs.minTabs;
  bool get _canAdd => _shown.length < NavPrefs.maxTabs;

  late DockTab _start = _prefs.startTab;

  /// The centre button is drawn from a real [DockTab]'s slot count, so it has
  /// to be mirrored here too: it is always on the bar and never editable.
  bool get _hasSwitcher => ZModePrefs.enabled;

  Future<void> _save() => _prefs.setTabs(_shown);

  Future<void> _setStart(DockTab t) async {
    setState(() => _start = t);
    await _prefs.setStartTab(t);
  }

  void _remove(DockTab t) {
    if (t.isPinned || !_canRemove) return;
    setState(() => _shown.remove(t));
    _save();
    // Dropping the landing tab would leave the picker with nothing checked
    // until the next launch re-resolved it. Move it now, visibly.
    if (_start == t) _setStart(_shown.first);
  }

  void _add(DockTab t) {
    if (!_canAdd) return;
    // Insert before the pinned tab so Profile stays at the end, where the
    // thumb expects it.
    final pinnedAt = _shown.indexWhere((x) => x.isPinned);
    setState(() => _shown.insert(pinnedAt < 0 ? _shown.length : pinnedAt, t));
    _save();
  }

  /// [ReorderableListView.onReorderItem] hands back a newIndex already
  /// adjusted for the removed row, so there's no off-by-one fixup to do here.
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final t = _shown.removeAt(oldIndex);
      _shown.insert(newIndex, t);
    });
    _save();
  }

  Future<void> _reset() async {
    await _prefs.reset();
    if (!mounted) return;
    setState(() {
      _shown = List.of(_prefs.tabs);
      _start = _prefs.startTab;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hidden = _hidden;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        l10n.navigationBar,
        actions: [
          TextButton(
            onPressed: _prefs.isDefault ? null : _reset,
            child: Text(
              l10n.reset,
              style: AppText.button.copyWith(
                color: _prefs.isDefault
                    ? AppColors.textTertiary
                    : AppColors.accent,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          _preview(),
          const SizedBox(height: 4),
          SettingsSectionLabel(
            // The cap is visible before you hit it, rather than discovered as
            // a greyed-out button.
            l10n.navTabsOnBar(_shown.length, NavPrefs.maxTabs),
            first: true,
          ),
          SettingsCard(
            children: [
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: _reorder,
                children: [
                  for (var i = 0; i < _shown.length; i++)
                    _row(_shown[i], index: i),
                ],
              ),
              // Listed but not editable: it explains the sixth icon in the
              // preview, which otherwise looks like the count is wrong.
              if (_hasSwitcher) _switcherRow(),
            ],
          ),
          SettingsSectionLabel(l10n.navTabsOpensOn),
          SettingsCard(children: [for (final t in _shown) _startRow(t)]),
          SettingsSectionLabel(l10n.navTabsNotShown),
          SettingsCard(
            children: hidden.isEmpty
                ? [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: Text(
                          l10n.navTabsEveryTabOnBar,
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ]
                : [for (final t in hidden) _row(t)],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
            child: Text(
              l10n.navTabsHelp(NavPrefs.minTabs, NavPrefs.maxTabs),
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// The dock as it will actually look — same frosted capsule, same glyphs,
  /// same outline→fill active state, redrawn as you edit.
  Widget _preview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 104,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2B3350), Color(0xFF4A3450), Color(0xFF233042)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                      child: Row(
                        children: [
                          // Split where _FloatingDock splits, so the centre
                          // button sits exactly where it will on the phone.
                          for (final t in _shown.take(_shown.length ~/ 2))
                            Expanded(child: _previewItem(t, t == _start)),
                          if (_hasSwitcher) _previewFab(),
                          for (final t in _shown.skip(_shown.length ~/ 2))
                            Expanded(child: _previewItem(t, t == _start)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewItem(DockTab t, bool active) {
    final color = active ? AppColors.accent : AppColors.textSecondary;
    final glyph = dockGlyphFor(t);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 19,
          child: Center(
            child: glyph != null
                ? DockIcon(glyph, color: color, filled: active, size: 18)
                : Icon(_iconFor(t, active), size: 18, color: color),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          t.localizedLabel(context),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 8,
            letterSpacing: 0.1,
            color: color,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }

  /// The mode switcher, at the preview's scale. Static: this screen edits the
  /// bar, not the mode, so tapping it here would be a trap.
  Widget _previewFab() {
    final mode = sl.isRegistered<ContentModeCubit>()
        ? sl<ContentModeCubit>().state
        : ContentMode.anime;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(
          iconForMode(mode, ZModePrefs.streamKind),
          color: Colors.white,
          size: 15,
        ),
      ),
    );
  }

  Widget _switcherRow() {
    final l10n = context.l10n;
    final mode = sl.isRegistered<ContentModeCubit>()
        ? sl<ContentModeCubit>().state
        : ContentMode.anime;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Row(
        children: [
          const SizedBox(width: 29),
          SizedBox(
            width: 20,
            child: Center(
              child: Icon(
                iconForMode(mode, ZModePrefs.streamKind),
                size: 19,
                color: AppColors.accent,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.navTabsSwitcher,
                  style: AppText.body.copyWith(
                    color: AppColors.textPrimary,
                    fontSize: 14.5,
                  ),
                ),
                Text(
                  l10n.navTabsSwitcherWhy,
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              l10n.pinned,
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _startRow(DockTab t) {
    final chosen = t == _start;
    final glyph = dockGlyphFor(t);
    final tint = chosen ? AppColors.accent : AppColors.textSecondary;
    return InkWell(
      onTap: chosen ? null : () => _setStart(t),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Center(
                child: glyph != null
                    ? DockIcon(glyph, color: tint, filled: chosen, size: 19)
                    : Icon(_iconFor(t, chosen), size: 19, color: tint),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t.localizedLabel(context),
                style: AppText.body.copyWith(
                  color: chosen
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontSize: 14.5,
                ),
              ),
            ),
            if (chosen)
              // Not const: accent is repainted from the wallpaper at runtime.
              Icon(Icons.check_rounded, size: 19, color: AppColors.accent),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(DockTab t, bool active) => switch (t) {
    DockTab.downloads =>
      active ? Icons.download_rounded : Icons.download_outlined,
    DockTab.history => active ? Icons.history_rounded : Icons.history_outlined,
    _ => active ? Icons.person_rounded : Icons.person_outline_rounded,
  };

  Widget _row(DockTab t, {int? index}) {
    final l10n = context.l10n;
    final onBar = index != null;
    final tint = onBar ? AppColors.textPrimary : AppColors.textTertiary;
    final glyph = dockGlyphFor(t);
    return Padding(
      key: ValueKey('${onBar ? 'on' : 'off'}_${t.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          if (onBar)
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 19,
                  color: AppColors.textTertiary,
                ),
              ),
            )
          else
            const SizedBox(width: 29),
          SizedBox(
            width: 20,
            child: Center(
              child: glyph != null
                  ? DockIcon(glyph, color: tint, size: 19)
                  : Icon(_iconFor(t, false), size: 19, color: tint),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t.localizedLabel(context),
              style: AppText.body.copyWith(color: tint, fontSize: 14.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (t.isPinned)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                l10n.pinned,
                style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 11.5,
                ),
              ),
            )
          else
            _action(t, onBar),
        ],
      ),
    );
  }

  Widget _action(DockTab t, bool onBar) {
    final l10n = context.l10n;
    final enabled = onBar ? _canRemove : _canAdd;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      tooltip: onBar
          ? (enabled
                ? l10n.navTabsRemove
                : l10n.navTabsKeepMinTabs(NavPrefs.minTabs))
          : (enabled ? l10n.navTabsAdd : l10n.navTabsBarFull),
      icon: Icon(
        onBar
            ? Icons.remove_circle_outline_rounded
            : Icons.add_circle_outline_rounded,
        size: 20,
        color: enabled
            ? (onBar ? AppColors.textSecondary : AppColors.accent)
            : AppColors.textTertiary.withValues(alpha: 0.35),
      ),
      onPressed: enabled ? () => onBar ? _remove(t) : _add(t) : null,
    );
  }
}
