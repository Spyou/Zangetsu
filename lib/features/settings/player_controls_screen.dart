import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../player/player_controls_config.dart';

/// Arrange the player's bottom bar: reorder within a side, move between sides,
/// hide what you don't use.
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
  late List<String> _left;
  late List<String> _right;

  @override
  void initState() {
    super.initState();
    final cfg = PlayerControlsConfig(
      left: _prefs.playerBarLeft ?? PlayerControlsConfig.defaultLeft,
      right: _prefs.playerBarRight ?? PlayerControlsConfig.defaultRight,
    ).sanitised();
    _left = [...cfg.left];
    _right = [...cfg.right];
  }

  List<String> get _hidden =>
      PlayerControlsConfig(left: _left, right: _right).hidden;

  void _save() => _prefs.setPlayerBar(_left, _right);

  void _apply(VoidCallback change) {
    setState(change);
    _save();
  }

  // onReorderItem (not the deprecated onReorder) already accounts for the
  // dragged row being lifted out, so `to` needs no off-by-one correction here.
  void _reorder(List<String> list, int from, int to) =>
      _apply(() => list.insert(to, list.removeAt(from)));

  void _moveSide(String id) => _apply(() {
    if (_left.remove(id)) {
      _right.add(id);
    } else if (_right.remove(id)) {
      _left.add(id);
    } else {
      _left.add(id); // was hidden — arrow brings it back onto the bar
    }
  });

  void _hide(String id) => _apply(() {
    _left.remove(id);
    _right.remove(id);
  });

  void _show(String id) => _apply(() => _left.add(id));

  Future<void> _reset() async {
    await _prefs.resetPlayerBar();
    if (!mounted) return;
    setState(() {
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
          const SettingsSectionLabel('Left side'),
          _sideCard(_left),
          const SettingsSectionLabel('Right side'),
          _sideCard(_right),
          const SettingsSectionLabel('Hidden'),
          _hiddenCard(),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
            child: Text(
              'Drag to reorder. The arrow moves a control to the other side, '
              'the eye hides it. Hidden controls are still available in the '
              '⋮ More menu inside the player.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// A miniature of the real bar. Without it you're editing a list and
  /// guessing what the player ends up looking like.
  Widget _preview() {
    Widget group(List<String> ids) => DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(19),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in ids)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  controlById(id)?.icon ?? Icons.help_outline,
                  size: 17,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 84,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2B3350), Color(0xFF4A3450), Color(0xFF233042)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7, left: 2),
                  child: Text(
                    'PREVIEW',
                    style: AppText.caption.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                      fontSize: 10,
                      letterSpacing: 0.6,
                    ),
                  ),
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

  Widget _sideCard(List<String> ids) {
    if (ids.isEmpty) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                'Nothing here — move a control across with its arrow.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      );
    }
    final toRight = identical(ids, _left);
    return SettingsCard(
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (f, t) => _reorder(ids, f, t),
          children: [
            for (var i = 0; i < ids.length; i++)
              _row(
                key: ValueKey('${toRight ? 'l' : 'r'}_${ids[i]}'),
                id: ids[i],
                index: i,
                trailing: toRight
                    ? Icons.chevron_right_rounded
                    : Icons.chevron_left_rounded,
                onTrailing: () => _moveSide(ids[i]),
                onEye: () => _hide(ids[i]),
                hidden: false,
              ),
          ],
        ),
      ],
    );
  }

  Widget _hiddenCard() {
    final ids = _hidden;
    if (ids.isEmpty) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                'Every control is on the bar.',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      );
    }
    return SettingsCard(
      children: [
        for (var i = 0; i < ids.length; i++)
          _row(
            key: ValueKey('h_${ids[i]}'),
            id: ids[i],
            index: i,
            trailing: Icons.chevron_right_rounded,
            onTrailing: () => _show(ids[i]),
            onEye: () => _show(ids[i]),
            hidden: true,
          ),
      ],
    );
  }

  Widget _row({
    required Key key,
    required String id,
    required int index,
    required IconData trailing,
    required VoidCallback onTrailing,
    required VoidCallback onEye,
    required bool hidden,
  }) {
    final c = controlById(id)!;
    final dim = hidden ? AppColors.textTertiary : AppColors.textPrimary;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          if (!hidden)
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
          Icon(c.icon, size: 20, color: dim),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              c.label,
              style: AppText.body.copyWith(color: dim, fontSize: 14.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (c.pinned)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                'Pinned',
                style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 11.5,
                ),
              ),
            )
          else
            _iconAction(
              icon: hidden
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              tooltip: hidden ? 'Show' : 'Hide',
              onTap: onEye,
            ),
          const SizedBox(width: 4),
          _iconAction(
            icon: trailing,
            tooltip: hidden ? 'Add to the bar' : 'Move to the other side',
            onTap: onTrailing,
          ),
        ],
      ),
    );
  }

  Widget _iconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(icon, size: 17, color: AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
