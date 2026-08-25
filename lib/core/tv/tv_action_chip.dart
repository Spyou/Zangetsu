import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_focusable.dart';

/// Compact TV action chip used on source rows (Install / Update / Installed).
///
/// Accent-filled chips cannot use [TvFocusVariant.row] — the red wash/border
/// is invisible on a red button. Focus matches posters: white outline + light
/// scale ([TvFocusVariant.float]).
class TvActionChip extends StatelessWidget {
  const TvActionChip({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.emphasized = true,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  /// Accent fill + white label (Install / Update). When false, outlined
  /// secondary style (Installed).
  final bool emphasized;

  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Color fg =
        emphasized ? Colors.white : AppColors.textSecondary;
    // scale 1.0 — dense rows sit in clipped lists; outline alone is enough.
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      variant: TvFocusVariant.float,
      scale: 1.0,
      borderRadius: 10,
      semanticLabel: semanticLabel ?? label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: emphasized ? AppColors.accent : Colors.transparent,
            border: emphasized
                ? null
                : Border.all(
                    color: AppColors.textSecondary.withValues(alpha: 0.4),
                  ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: AppText.caption.copyWith(
                  color: fg,
                  fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
