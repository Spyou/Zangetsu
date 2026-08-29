import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_focusable.dart';

/// D-pad focusable episode-range chips (`1–50`, `51–100`, …).
///
/// [axis] is [Axis.horizontal] for the detail tab row, or [Axis.vertical]
/// for the player overlay's left rail.
class TvEpisodeRangeChips extends StatelessWidget {
  const TvEpisodeRangeChips({
    super.key,
    required this.count,
    required this.selected,
    required this.labelFor,
    required this.onSelect,
    this.axis = Axis.horizontal,
    this.selectedChipFocusNode,
    this.episodeReturnFocusNode,
  });

  final int count;
  final int selected;
  final String Function(int) labelFor;
  final ValueChanged<int> onSelect;
  final Axis axis;

  /// When set, wired to the selected chip so callers can focus it from the
  /// episode list (◀ enters the rail on the active range, not the first).
  final FocusNode? selectedChipFocusNode;

  /// When set, ◀▶ from a chip returns focus to the episode list (usually the
  /// current episode row).
  final FocusNode? episodeReturnFocusNode;

  static const double _chipHeight = 32;
  static const double _chipRadius = 20;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();

    final list = ListView.separated(
      primary: false,
      scrollDirection: axis,
      padding: axis == Axis.horizontal
          ? const EdgeInsets.symmetric(horizontal: 16)
          : const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      itemCount: count,
      separatorBuilder: (_, _) => axis == Axis.horizontal
          ? const SizedBox(width: 8)
          : const SizedBox(height: 8),
      itemBuilder: (_, i) => _chip(i),
    );

    return axis == Axis.horizontal
        ? SizedBox(height: 48, child: list)
        : SizedBox(
            width: 96,
            child: list,
          );
  }

  Widget _chip(int i) {
    final label = labelFor(i);
    final isSelected = i == selected;
    final chip = TvFocusable(
      key: ValueKey('tv-range-$i'),
      variant: TvFocusVariant.box,
      scale: 1.0,
      borderRadius: _chipRadius,
      focusNode: isSelected ? selectedChipFocusNode : null,
      onTap: () => onSelect(i),
      semanticLabel: label,
      builder: (_) => Container(
        height: _chipHeight,
        constraints: axis == Axis.horizontal
            ? const BoxConstraints(minWidth: 72)
            : const BoxConstraints(minWidth: 80),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accent : AppColors.surface2,
          borderRadius: BorderRadius.circular(_chipRadius),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(
            color: isSelected ? Colors.white : AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    );
    final returnFocus = episodeReturnFocusNode;
    if (returnFocus == null) return chip;
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          returnFocus.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: chip,
    );
  }
}
