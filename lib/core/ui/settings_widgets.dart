import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// One row inside a [SettingsCard]. Compact: leading icon + title
/// (Expanded) + optional short subtitle/value + trailing chevron (or a
/// custom [trailing] widget such as a [Switch]). Set [destructive] to
/// render the row in the accent-red danger tint.
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
    final trailingWidget = trailing ??
        (onTap == null
            ? null
            : const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textTertiary,
                size: 22,
              ));
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: AppColors.accent.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: fg ?? AppColors.textSecondary, size: 22),
            const SizedBox(width: 14),
            // Title claims all remaining width so the trailing widget /
            // chevron always lands at the same far-right position
            // regardless of subtitle length.
            Expanded(
              child: Text(
                title,
                style: AppText.headline.copyWith(
                  color: fg ?? AppColors.textPrimary,
                  fontWeight: FontWeight.w500,
                  fontSize: 15,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  subtitle!,
                  style: AppText.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (trailingWidget != null) ...[
              const SizedBox(width: 8),
              trailingWidget,
            ],
          ],
        ),
      ),
    );
  }
}

/// Groups a set of rows into a rounded [AppColors.surface] card with a
/// thin hairline divider between each child. Mirrors the iOS Settings
/// look in our dark language.
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
        separated.add(const Divider(
          height: 0.5,
          thickness: 0.5,
          indent: 52,
          color: AppColors.hairline,
        ));
      }
    }
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(16, 6, 16, 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: separated,
      ),
    );
  }
}

/// Small uppercase label drawn above a card. Use sparingly.
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: AppText.overline.copyWith(color: AppColors.textTertiary),
      ),
    );
  }
}
