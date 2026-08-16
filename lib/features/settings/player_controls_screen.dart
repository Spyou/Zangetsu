import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../player/player_controls_config.dart';

/// Arrange the player's controls: which bar each one sits on, in what order,
/// and which are put away.
///
/// Hidden controls stay reachable in the player's ⋮ More sheet, so nothing
/// here can make a feature unavailable — it only decides what's one tap away.
class PlayerControlsScreen extends StatefulWidget {
  const PlayerControlsScreen({super.key});

  @override
  State<PlayerControlsScreen> createState() => _PlayerControlsScreenState();
}

class _PlayerControlsScreenState extends State<PlayerControlsScreen> {
  final PlaybackPrefs _prefs = sl<PlaybackPrefs>();
  late List<String> _top;
  late List<String> _left;
  late List<String> _right;

  @override
  void initState() {
    super.initState();
    final cfg = PlayerControlsConfig(
      top: _prefs.playerBarTop ?? PlayerControlsConfig.defaultTop,
      left: _prefs.playerBarLeft ?? PlayerControlsConfig.defaultLeft,
      right: _prefs.playerBarRight ?? PlayerControlsConfig.defaultRight,
    ).sanitised();
    _top = [...cfg.top];
    _left = [...cfg.left];
    _right = [...cfg.right];
  }

  PlayerControlsConfig get _cfg =>
      PlayerControlsConfig(top: _top, left: _left, right: _right);

  void _apply(VoidCallback change) {
    setState(change);
    _prefs.setPlayerBar(_top, _left, _right);
  }

  // onReorderItem (not the deprecated onReorder) already accounts for the
  // dragged row being lifted out, so `to` needs no off-by-one correction.
  void _reorder(List<String> list, int from, int to) =>
      _apply(() => list.insert(to, list.removeAt(from)));

  void _moveTo(String id, ControlSlot slot) => _apply(() {
    // Enforced here as well as in the menu — the menu greys the option out,
    // but the cap shouldn't depend on the UI being the only way in.
    if (slot == ControlSlot.top &&
        !_top.contains(id) &&
        _top.length >= PlayerControlsConfig.maxTop) {
      return;
    }
    _top.remove(id);
    _left.remove(id);
    _right.remove(id);
    switch (slot) {
      case ControlSlot.top:
        _top.add(id);
      case ControlSlot.left:
        _left.add(id);
      case ControlSlot.right:
        _right.add(id);
      case ControlSlot.hidden:
        break; // hidden is "in no list"
    }
  });

  Future<void> _reset() async {
    await _prefs.resetPlayerBar();
    if (!mounted) return;
    setState(() {
      _top = [...PlayerControlsConfig.defaultTop];
      _left = [...PlayerControlsConfig.defaultLeft];
      _right = [...PlayerControlsConfig.defaultRight];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: const Text('Player controls'),
        actions: [
          TextButton(
            onPressed: _reset,
            child: Text(
              'Reset',
              style: AppText.body.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          _preview(),
          const SizedBox(height: 4),
          for (final slot in ControlSlot.values) ...[
            SettingsSectionLabel(
              slot == ControlSlot.top
                  // Shown so the limit is visible before you hit it, rather
                  // than discovered as a greyed-out menu item.
                  ? '${slot.label} · ${_top.length}/${PlayerControlsConfig.maxTop}'
                  : slot.label,
            ),
            _card(slot),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
            child: Text(
              'Drag to reorder within a bar. Use Move to send a control '
              'somewhere else. Hidden controls are still available in the '
              '⋮ More menu inside the player.\n\n'
              'Back, Lock and Settings are fixed in the top bar, and the show '
              'title shares that row — the more you put up there, the less '
              'room the title has.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// A miniature of both bars. Without it you're editing lists and guessing
  /// what the player ends up looking like — and it's the only way to see the
  /// title being squeezed as controls pile into the top bar.
  Widget _preview() {
    Widget icons(List<String> ids) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              controlById(id)?.icon ?? Icons.help_outline,
              size: 16,
              color: Colors.white,
            ),
          ),
      ],
    );

    Widget group(List<String> ids) => DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(19),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: icons(ids),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 116,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2B3350), Color(0xFF4A3450), Color(0xFF233042)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              children: [
                // Top bar: back, the title, then whatever's been put up here,
                // then the fixed lock + settings.
                Row(
                  children: [
                    const Icon(
                      Icons.arrow_back_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Show title · E2',
                        style: AppText.caption.copyWith(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    icons(_top),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.lock_open_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.settings_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    if (_left.isNotEmpty) group(_left),
                    const Spacer(),
                    if (_right.isNotEmpty) group(_right),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(ControlSlot slot) {
    final ids = _cfg.forSlot(slot);
    if (ids.isEmpty) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                slot == ControlSlot.hidden
                    ? 'Every control is on a bar.'
                    : 'Nothing here — move a control across with Move.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      );
    }
    // Hidden has no meaningful order, so it doesn't get drag handles.
    if (slot == ControlSlot.hidden) {
      return SettingsCard(
        children: [for (final id in ids) _row(id, slot, null)],
      );
    }
    return SettingsCard(
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (f, t) => _reorder(ids, f, t),
          children: [
            for (var i = 0; i < ids.length; i++) _row(ids[i], slot, i),
          ],
        ),
      ],
    );
  }

  Widget _row(String id, ControlSlot slot, int? index) {
    final c = controlById(id)!;
    final hidden = slot == ControlSlot.hidden;
    final tint = hidden ? AppColors.textTertiary : AppColors.textPrimary;
    return Padding(
      key: ValueKey('${slot.name}_$id'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          if (index != null)
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
          Icon(c.icon, size: 20, color: tint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              c.label,
              style: AppText.body.copyWith(color: tint, fontSize: 14.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (c.pinned)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Pinned',
                style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 11.5,
                ),
              ),
            ),
          _moveMenu(id, slot, c.pinned),
        ],
      ),
    );
  }

  /// Four destinations means the old "send it to the other side" arrow no
  /// longer says enough, so each row picks its slot explicitly.
  Widget _moveMenu(String id, ControlSlot from, bool pinned) {
    // A pinned control can go anywhere except away — it's the route back to
    // everything in Hidden.
    final options = [
      for (final s in ControlSlot.values)
        if (s != from && !(pinned && s == ControlSlot.hidden)) s,
    ];
    final topFull = _top.length >= PlayerControlsConfig.maxTop;
    return PopupMenuButton<ControlSlot>(
      tooltip: 'Move',
      color: AppColors.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      onSelected: (s) => _moveTo(id, s),
      itemBuilder: (c) => [
        for (final s in options)
          // A full top bar is offered greyed out rather than dropped from the
          // menu — "Top bar (full)" explains itself; a missing row doesn't.
          PopupMenuItem<ControlSlot>(
            value: s,
            height: 42,
            enabled: !(s == ControlSlot.top && topFull),
            child: Text(
              s == ControlSlot.top && topFull ? '${s.label} (full)' : s.label,
              style: AppText.caption.copyWith(
                color: s == ControlSlot.top && topFull
                    ? AppColors.textTertiary
                    : AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Move',
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
