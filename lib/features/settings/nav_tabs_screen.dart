import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/nav_prefs.dart';
import '../../core/ui/settings_widgets.dart';
import '../shell/dock_icons.dart';

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

  List<DockTab> get _hidden =>
      [for (final t in DockTab.values) if (!_shown.contains(t)) t];

  bool get _canRemove => _shown.length > NavPrefs.minTabs;
  bool get _canAdd => _shown.length < NavPrefs.maxTabs;

  Future<void> _save() => _prefs.setTabs(_shown);

  void _remove(DockTab t) {
    if (t.isPinned || !_canRemove) return;
    setState(() => _shown.remove(t));
    _save();
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
    setState(() => _shown = List.of(_prefs.tabs));
  }

  @override
  Widget build(BuildContext context) {
    final hidden = _hidden;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        'Navigation bar',
        actions: [
          TextButton(
            onPressed: _prefs.isDefault ? null : _reset,
            child: Text(
              'Reset',
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
            'On the bar · ${_shown.length}/${NavPrefs.maxTabs}',
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
            ],
          ),
          const SettingsSectionLabel('Not shown'),
          SettingsCard(
            children: hidden.isEmpty
                ? [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: Text(
                          'Every tab is on the bar.',
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
              'Drag to reorder. ${NavPrefs.minTabs}–${NavPrefs.maxTabs} tabs '
              'fit on the bar.\n\n'
              'Profile is pinned because it is the only way into Settings — '
              'hiding it would leave no way back to this screen. Schedule only '
              'appears in Streaming mode; there is no airing schedule to show '
              'while you are reading.',
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
                          // First tab drawn active, exactly as the dock lands
                          // on open.
                          for (var i = 0; i < _shown.length; i++)
                            Expanded(child: _previewItem(_shown[i], i == 0)),
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
          t.label,
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

  IconData _iconFor(DockTab t, bool active) => switch (t) {
    DockTab.downloads =>
      active ? Icons.download_rounded : Icons.download_outlined,
    DockTab.history => active ? Icons.history_rounded : Icons.history_outlined,
    _ => active ? Icons.person_rounded : Icons.person_outline_rounded,
  };

  Widget _row(DockTab t, {int? index}) {
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
              t.label,
              style: AppText.body.copyWith(color: tint, fontSize: 14.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (t.isAnimeOnly)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Streaming only',
                style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 11.5,
                ),
              ),
            ),
          if (t.isPinned)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                'Pinned',
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
    final enabled = onBar ? _canRemove : _canAdd;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      tooltip: onBar
          ? (enabled ? 'Remove' : 'Keep at least ${NavPrefs.minTabs} tabs')
          : (enabled ? 'Add' : 'The bar is full'),
      icon: Icon(
        onBar
            ? Icons.remove_circle_outline_rounded
            : Icons.add_circle_outline_rounded,
        size: 20,
        color: enabled
            ? (onBar ? AppColors.textSecondary : AppColors.accent)
            : AppColors.textTertiary.withValues(alpha: 0.35),
      ),
      onPressed:
          enabled ? () => onBar ? _remove(t) : _add(t) : null,
    );
  }
}
