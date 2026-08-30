import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/reading/tap_zones.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

/// Assign what tapping each part of the page does, per reading mode.
///
/// Shown as a map of the screen rather than a list of rows: the whole point is
/// WHERE you tap, and a list of "left / middle / right" reads as three
/// unrelated settings instead of one picture.
class TapZonesScreen extends StatefulWidget {
  const TapZonesScreen({super.key});

  @override
  State<TapZonesScreen> createState() => _TapZonesScreenState();
}

class _TapZonesScreenState extends State<TapZonesScreen> {
  String _layoutId = TapZoneLayout.paged;

  ReaderPrefs get _prefs => sl<ReaderPrefs>();

  /// Mirrors the reader's own modes: left-to-right and right-to-left share the
  /// paged layout, vertical is the strip.
  List<({String id, String label})> get _modes => [
    (id: TapZoneLayout.paged, label: context.l10n.paged),
    (id: TapZoneLayout.webtoon, label: context.l10n.vertical),
  ];

  /// Only what makes sense for the mode being edited — offering "next page" on
  /// a continuous strip, or "scroll down" on a fixed page, just gives you a
  /// zone that does nothing.
  List<ReaderAction> get _actions {
    final scrolls = _layoutId == TapZoneLayout.webtoon;
    return [
      ReaderAction.toggleMenu,
      if (scrolls) ...[ReaderAction.scrollUp, ReaderAction.scrollDown],
      if (!scrolls) ...[ReaderAction.prevPage, ReaderAction.nextPage],
      ReaderAction.prevChapter,
      ReaderAction.nextChapter,
      ReaderAction.none,
    ];
  }

  Future<void> _assign(int index, TapZoneLayout layout) async {
    final picked = await showModalBottomSheet<ReaderAction>(
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
            for (final a in _actions)
              ListTile(
                title: Text(
                  a.label,
                  style: AppText.body.copyWith(
                    color: a == layout.zones[index].action
                        ? AppColors.accent
                        : AppColors.textPrimary,
                  ),
                ),
                trailing: a == layout.zones[index].action
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _prefs.setTapZones(layout.withZoneAction(index, picked));
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    await _prefs.resetTapZones();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(context.l10n.tapZonesReset)));
  }

  @override
  Widget build(BuildContext context) {
    final layout = _prefs.tapZones(_layoutId);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        context.l10n.tapZones,
        actions: [
          TextButton(
            onPressed: _reset,
            child: Text(
              context.l10n.reset,
              style: AppText.button.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.modeLabel, first: true),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final m in _modes) ...[
                  Expanded(
                    child: _ModeChip(
                      label: m.label,
                      selected: _layoutId == m.id,
                      onTap: () => setState(() => _layoutId = m.id),
                    ),
                  ),
                  if (m != _modes.last) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          SettingsSectionLabel(context.l10n.tapAZoneToChangeIt),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: AspectRatio(
              // Roughly a phone screen, so the map reads as the page you'd be
              // looking at rather than an abstract grid.
              aspectRatio: 0.62,
              child: _ZoneMap(
                layout: layout,
                onTapZone: (i) => _assign(i, layout),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              _layoutId == TapZoneLayout.webtoon
                  ? context.l10n.usedInVerticalMode
                  : context.l10n.usedWhenPagesTurn,
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.accent : AppColors.surface,
    borderRadius: BorderRadius.circular(10),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Text(
            label,
            style: AppText.body.copyWith(
              color: selected ? Colors.white : AppColors.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The zones drawn to scale, each tappable where it actually sits.
class _ZoneMap extends StatelessWidget {
  const _ZoneMap({required this.layout, required this.onTapZone});

  final TapZoneLayout layout;
  final ValueChanged<int> onTapZone;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surface2),
        ),
        child: Stack(
          children: [
            for (var i = 0; i < layout.zones.length; i++)
              Positioned(
                left: layout.zones[i].bounds.left * c.maxWidth,
                top: layout.zones[i].bounds.top * c.maxHeight,
                width: layout.zones[i].bounds.width * c.maxWidth,
                height: layout.zones[i].bounds.height * c.maxHeight,
                child: _ZoneCell(
                  action: layout.zones[i].action,
                  onTap: () => onTapZone(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ZoneCell extends StatelessWidget {
  const _ZoneCell({required this.action, required this.onTap});

  final ReaderAction action;
  final VoidCallback onTap;

  IconData get _icon => switch (action) {
    ReaderAction.nextPage => Icons.chevron_right_rounded,
    ReaderAction.prevPage => Icons.chevron_left_rounded,
    ReaderAction.toggleMenu => Icons.touch_app_outlined,
    ReaderAction.scrollUp => Icons.keyboard_arrow_up_rounded,
    ReaderAction.scrollDown => Icons.keyboard_arrow_down_rounded,
    ReaderAction.nextChapter => Icons.last_page_rounded,
    ReaderAction.prevChapter => Icons.first_page_rounded,
    ReaderAction.none => Icons.block_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final dead = action == ReaderAction.none;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: dead
            ? AppColors.surface2.withValues(alpha: 0.4)
            : AppColors.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _icon,
                  color: dead ? AppColors.textTertiary : AppColors.accent,
                  size: 26,
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    action.label,
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(
                      color: dead
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
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
}
