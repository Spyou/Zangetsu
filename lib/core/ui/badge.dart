import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Small pill badge used for "DUB" / "SUB" / "NEW" / "FILLER" labels.
///
/// Named [TagBadge] to avoid collision with Flutter's built-in [Badge] widget.
class TagBadge extends StatelessWidget {
  const TagBadge({super.key, required this.text, this.color});

  final String text;

  /// When provided, fills with [color] @ 15% alpha and labels in [color].
  /// Defaults to [AppColors.accentSoft] fill / [AppColors.accent] label.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final labelColor = color ?? AppColors.accent;
    final fillColor = color != null
        ? color!.withValues(alpha: 0.15)
        : AppColors.accentSoft;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(text, style: AppText.overline.copyWith(color: labelColor)),
      ),
    );
  }
}
