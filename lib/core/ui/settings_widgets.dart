import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// One flat row inside a [SettingsCard]. Sits directly on the background:
/// thin monochrome line icon + title (Expanded) + optional short subtitle
/// under it + trailing value/switch and/or a subtle chevron. No colored
/// icon square, no card box. Set [destructive] for the accent-red danger tint.
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
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
        child: Row(
          children: [
            // Thin monochrome line icon, muted grey, no background square.
            Icon(icon, color: fg ?? AppColors.textSecondary, size: 20),
            const SizedBox(width: 15),
            // Title + subtitle stacked (subtitle sits UNDER the title), so long
            // values read cleanly and the trailing widget always lands right.
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
                      fontSize: 15,
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
              const SizedBox(width: 12),
              trailingWidget,
            ],
          ],
        ),
      ),
    );
  }
}

/// Groups rows into one flat list. No box, no border, no fill — the rows
/// float on the background, separated only by a single 1px hairline.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children, this.margin});

  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(
          const Divider(
            height: 1,
            thickness: 1,
            color: AppColors.hairline,
          ),
        );
      }
    }
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: separated),
    );
  }
}

/// Tiny uppercase section label drawn above a group. Muted, wide tracking.
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5, // ~.14em at 11px
          color: AppColors.textTertiary,
        ),
      ),
    );
  }
}
