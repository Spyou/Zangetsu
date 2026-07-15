import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// One Material-You list row. Sits directly on the background (no card box):
/// a roomy leading line icon + title with an optional description under it +
/// trailing chevron / switch / value. Set [destructive] for the danger tint.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Rendered on the right. When null and [onTap] is set, a chevron is
  /// drawn instead.
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Renders the icon + title in the coral danger tint.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? AppColors.accent : null;
    final trailingWidget =
        trailing ??
        (onTap == null
            ? null
            : const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textTertiary,
                size: 20,
              ));
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: AppColors.accent.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
        child: Row(
          children: [
            // Roomy monochrome line icon, muted grey (M3 leading icon).
            Icon(icon, color: fg ?? AppColors.textSecondary, size: 23),
            const SizedBox(width: 18),
            // Title + description stacked, so the trailing widget always lands
            // cleanly on the right regardless of subtitle length.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AppText.headline.copyWith(
                      color: fg ?? AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 15.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (trailingWidget != null) ...[
              const SizedBox(width: 14),
              trailingWidget,
            ],
          ],
        ),
      ),
    );
  }
}

/// Stacks the rows of one category. No box, no border, no dividers — rows just
/// sit on the background; category separation comes from [SettingsSectionLabel].
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children, this.margin});

  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin ?? EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// Material-You category header: an accent-coloured label, preceded by a full
/// hairline (except the [first] one) that visually separates the groups.
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.label, {super.key, this.first = false});
  final String label;

  /// The topmost section: no divider above it, tighter top padding.
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!first) ...[
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22),
            child: Divider(height: 1, thickness: 1, color: AppColors.hairline),
          ),
        ],
        Padding(
          padding: EdgeInsets.fromLTRB(22, first ? 6 : 18, 22, 8),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }
}
