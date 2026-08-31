import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tv/tv_list_focusable.dart';

/// Compact, flat app bar for pushed settings screens — an 18px title with a
/// bottom hairline, matching the in-tab section header so drilling deeper keeps
/// the same header. Inherits the transparent/flat [AppBarTheme].
/// Set [showBack] false when the screen is a nav-shell TAB rather than a pushed
/// page — there's nothing to pop back to, and the implicit arrow would be dead.
PreferredSizeWidget settingsAppBar(
  String title, {
  List<Widget>? actions,
  bool showBack = true,
}) {
  return AppBar(
    titleSpacing: showBack ? 4 : 16,
    automaticallyImplyLeading: showBack,
    title: Text(title, style: AppText.barTitle),
    actions: actions,
    bottom: const PreferredSize(
      preferredSize: Size.fromHeight(1),
      child: Divider(height: 1, thickness: 1, color: AppColors.hairline),
    ),
  );
}

bool _isTvDevice() =>
    sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

/// One settings list row inside a [SettingsCard]: a rounded tinted icon tile +
/// title with an optional description under it + trailing chevron / switch /
/// value. Set [destructive] for the danger tint, or [iconAccent] to tint the
/// icon tile with the accent (used for a card's lead row).
///
/// On TV, tappable rows are wrapped in [TvListFocusable] (white pill) so D-pad
/// focus sits on top of the opaque card — bare [InkWell] focus is invisible.
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
    this.autofocus = false,
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

  /// TV only: land D-pad focus here first (typically the first row on a page).
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final isTv = _isTvDevice();
    final tap = onTap;

    if (isTv && tap != null) {
      return TvListFocusable(
        autofocus: autofocus,
        semanticLabel: title,
        onTap: tap,
        child: ExcludeSemantics(
          child: _row(
            // Row activation owns the tap; disable InkWell under the focusable.
            onTap: null,
            // Switch / chevron must not steal D-pad traversal.
            wrapTrailing: true,
          ),
        ),
      );
    }

    return _row(onTap: tap, wrapTrailing: false);
  }

  Widget _row({
    required VoidCallback? onTap,
    required bool wrapTrailing,
  }) {
    final fg = destructive ? AppColors.accent : null;
    final accented = destructive || iconAccent;

    Widget? trailingWidget;
    if (trailing != null) {
      // Switches / custom trailings must not steal D-pad traversal on TV.
      trailingWidget = wrapTrailing ? ExcludeFocus(child: trailing!) : trailing;
    } else if (this.onTap != null) {
      trailingWidget = const Icon(
        Icons.chevron_right_rounded,
        color: AppColors.textTertiary,
        size: 20,
      );
    }

    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
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
    );

    if (onTap == null) return body;

    return InkWell(
      onTap: onTap,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: AppColors.accent.withValues(alpha: 0.04),
      child: body,
    );
  }
}

/// Groups its rows into one rounded surface card with inset hairline dividers
/// between them (iOS-grouped style). Category separation comes from the
/// [SettingsSectionLabel] above it.
///
/// On TV, [clipBehavior] is [Clip.none] so [TvListFocusable] / [TvFocusable]
/// focus chrome is not cropped at the card edges (phone keeps antiAlias so
/// Material ripples stay rounded).
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children, this.margin});

  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final isTv = _isTvDevice();
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
      margin: margin ??
          (isTv
              ? const EdgeInsets.fromLTRB(28, 0, 20, 0)
              : const EdgeInsets.fromLTRB(16, 0, 16, 0)),
      // TV focus pills/borders paint outside the row bounds — do not clip.
      clipBehavior: isTv ? Clip.none : Clip.antiAlias,
      decoration: BoxDecoration(
        // Dark card fill; icon tiles use a light overlay to still read on it.
        color: AppColors.settingsCard,
        borderRadius: BorderRadius.circular(16),
      ),
      // Tiny inset so first/last pill fills aren't flush against the card edge.
      padding: isTv ? const EdgeInsets.symmetric(vertical: 4) : EdgeInsets.zero,
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
          fontFamilyFallback: AppText.fontFamilyFallback,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: muted ? AppColors.textTertiary : AppColors.accent,
        ),
      ),
    );
  }
}
