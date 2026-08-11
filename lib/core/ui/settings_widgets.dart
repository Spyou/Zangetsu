import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Compact, flat app bar for pushed settings screens — an 18px title with a
/// bottom hairline, matching the in-tab section header so drilling deeper keeps
/// the same header. Inherits the transparent/flat [AppBarTheme].
PreferredSizeWidget settingsAppBar(String title, {List<Widget>? actions}) {
  return AppBar(
    titleSpacing: 4,
    title: Text(title, style: AppText.barTitle),
    actions: actions,
    bottom: const PreferredSize(
      preferredSize: Size.fromHeight(1),
      child: Divider(height: 1, thickness: 1, color: AppColors.hairline),
    ),
  );
}

/// One settings list row inside a [SettingsCard]: a rounded tinted icon tile +
/// title with an optional description under it + trailing chevron / switch /
/// value. Set [destructive] for the danger tint, or [iconAccent] to tint the
/// icon tile with the accent (used for a card's lead row).
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.subtitleMaxLines = 1,
    this.iconAccent = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Max description lines before ellipsis. Default 1 (compact tile); pass null
  /// to let a long description wrap fully (used by toggle rows).
  final int? subtitleMaxLines;

  /// Rendered on the right. When null and [onTap] is set, a chevron is
  /// drawn instead.
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Renders the icon + title in the coral danger tint.
  final bool destructive;

  /// Accent-tint the icon tile (a card's lead row).
  final bool iconAccent;

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? AppColors.accent : null;
    final accented = destructive || iconAccent;
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
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        child: Row(
          children: [
            // Icon in a rounded tinted tile — accent on a lead/destructive row.
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accented
                    ? AppColors.accent.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: accented ? AppColors.accent : AppColors.textSecondary,
                size: 19,
              ),
            ),
            const SizedBox(width: 14),
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
                      fontWeight: FontWeight.w600,
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
                        fontSize: 12.8,
                      ),
                      maxLines: subtitleMaxLines,
                      overflow: subtitleMaxLines == null
                          ? TextOverflow.clip
                          : TextOverflow.ellipsis,
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

/// Groups its rows into one rounded surface card with inset hairline dividers
/// between them (iOS-grouped style). Category separation comes from the
/// [SettingsSectionLabel] above it.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children, this.margin});

  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          const Padding(
            // Inset past the 34px icon tile so the divider starts at the text.
            padding: EdgeInsets.only(left: 63),
            child: Divider(height: 1, thickness: 1, color: AppColors.hairline),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(16, 0, 16, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // Dark card fill; icon tiles use a light overlay to still read on it.
        color: AppColors.settingsCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// Material-You category header: a small uppercase accent label above a
/// [SettingsCard]. No divider — the boxed cards separate the groups.
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(
    this.label, {
    super.key,
    this.first = false,
    this.muted = false,
  });
  final String label;

  /// The topmost section: tighter top padding.
  final bool first;

  /// Render in a quiet grey instead of the accent — for showcase screens (the
  /// About page) where accent-on-everything reads busy.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(28, first ? 4 : 22, 22, 9),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: muted ? AppColors.textTertiary : AppColors.accent,
        ),
      ),
    );
  }
}
