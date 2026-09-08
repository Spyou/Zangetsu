import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/zmode/source_order_prefs.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart' show candidatesForKind;

/// Reorder installed sources per content type. Auto Resolve (the default —
/// see `SourceMatcher`) sweeps sources in this order for every title that
/// hasn't been pinned to one by hand. Anime and Movies/TV get separate
/// orders: the same pool of sources serves both, but a source that's great
/// for one can return nothing for the other.
class SourcePriorityScreen extends StatefulWidget {
  const SourcePriorityScreen({super.key});

  @override
  State<SourcePriorityScreen> createState() => _SourcePriorityScreenState();
}

class _SourcePriorityScreenState extends State<SourcePriorityScreen> {
  SourceOrderPrefs get _prefs => sl<SourceOrderPrefs>();

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  late List<({String id, String name})> _anime = _ordered(ZKind.anime);
  late List<({String id, String name})> _movies = _ordered(ZKind.movie);

  List<({String id, String name})> _ordered(ZKind kind) => applySourceOrder(
    candidatesForKind(sl<SourceRepository>(), kind),
    _prefs.get(kind),
  );

  Future<void> _save(ZKind kind, List<({String id, String name})> list) =>
      _prefs.set(kind, [for (final s in list) s.id]);

  void _reorder(ZKind kind, int oldIndex, int newIndex) {
    final list = kind == ZKind.anime ? _anime : _movies;
    setState(() {
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
    });
    _save(kind, list);
  }

  /// D-pad path: move one row up/down by exactly one slot. No off-by-one
  /// fixup needed (unlike drag reordering) since the move is always ±1.
  void _move(ZKind kind, int index, int delta) {
    final list = kind == ZKind.anime ? _anime : _movies;
    final target = index + delta;
    if (target < 0 || target >= list.length) return;
    setState(() {
      final item = list.removeAt(index);
      list.insert(target, item);
    });
    _save(kind, list);
  }

  Future<void> _reset(ZKind kind) async {
    await _prefs.clear(kind);
    if (!mounted) return;
    setState(() {
      if (kind == ZKind.anime) {
        _anime = _ordered(ZKind.anime);
      } else {
        _movies = _ordered(ZKind.movie);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Source Priority'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          const SettingsSectionLabel('ANIME', first: true),
          _section(ZKind.anime, _anime),
          const SettingsSectionLabel('MOVIES & TV'),
          _section(ZKind.movie, _movies),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
            child: Text(
              _isTv
                  ? 'Auto Resolve tries sources in this order for every '
                        'title that hasn\'t been pinned to a specific one '
                        'from its own Detail screen. Use the arrows to '
                        'reorder.'
                  : 'Auto Resolve tries sources in this order for every '
                        'title that hasn\'t been pinned to a specific one '
                        'from its own Detail screen. Drag to reorder.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(ZKind kind, List<({String id, String name})> list) {
    if (list.isEmpty) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                'No sources installed',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      );
    }
    return SettingsCard(
      children: [
        if (_isTv)
          Column(
            children: [
              for (var i = 0; i < list.length; i++)
                _tvRow(kind, list[i], i, list.length),
            ],
          )
        else
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (oldIndex, newIndex) =>
                _reorder(kind, oldIndex, newIndex),
            children: [
              for (var i = 0; i < list.length; i++) _row(list[i], i),
            ],
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
          child: Align(
            alignment: Alignment.centerRight,
            child: _isTv
                ? TvFocusable(
                    variant: TvFocusVariant.pill,
                    onTap: () => _reset(kind),
                    semanticLabel: 'Reset order',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        'Reset order',
                        style: AppText.button.copyWith(
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                  )
                : TextButton(
                    onPressed: () => _reset(kind),
                    child: Text(
                      'Reset order',
                      style: AppText.button.copyWith(color: AppColors.accent),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _row(({String id, String name}) s, int index) {
    return Padding(
      key: ValueKey(s.id),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
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
          ),
          Expanded(
            child: Text(
              s.name,
              style: AppText.body.copyWith(
                color: AppColors.textPrimary,
                fontSize: 14.5,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${index + 1}',
            style: AppText.caption.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  /// TV row: up/down arrows instead of a drag handle — dragging isn't
  /// D-pad-drivable, so this is the only way to reorder with a remote.
  Widget _tvRow(
    ZKind kind,
    ({String id, String name}) s,
    int index,
    int count,
  ) {
    return Padding(
      key: ValueKey(s.id),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.name,
              style: AppText.body.copyWith(
                color: AppColors.textPrimary,
                fontSize: 14.5,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _tvMoveButton(
            icon: Icons.keyboard_arrow_up_rounded,
            enabled: index > 0,
            semanticLabel: 'Move ${s.name} up',
            onTap: () => _move(kind, index, -1),
          ),
          const SizedBox(width: 6),
          _tvMoveButton(
            icon: Icons.keyboard_arrow_down_rounded,
            enabled: index < count - 1,
            semanticLabel: 'Move ${s.name} down',
            onTap: () => _move(kind, index, 1),
          ),
        ],
      ),
    );
  }

  Widget _tvMoveButton({
    required IconData icon,
    required bool enabled,
    required String semanticLabel,
    required VoidCallback onTap,
  }) {
    return TvFocusable(
      variant: TvFocusVariant.pill,
      scale: 1.0,
      semanticLabel: semanticLabel,
      onTap: enabled ? onTap : () {},
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 22,
          color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
        ),
      ),
    );
  }
}
