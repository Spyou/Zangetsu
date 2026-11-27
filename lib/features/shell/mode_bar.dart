import '../../core/ui/adaptive_layout.dart';
import 'package:flutter/material.dart';

import '../../core/mode/content_mode.dart';
import '../../core/ui/frosted_surface.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';

typedef ModeChoice = ({
  String Function(BuildContext) label,
  IconData icon,
  ContentMode mode,
  StreamKind kind,
});

/// The four things the centre button can switch to. Movie/TV shares the
/// `anime` content mode and differs by [StreamKind].
final List<ModeChoice> modeChoices = [
  (
    label: (c) => c.l10n.modeAnime,
    icon: Icons.play_circle_outline_rounded,
    mode: ContentMode.anime,
    kind: StreamKind.anime,
  ),
  (
    label: (c) => c.l10n.modeMovieTv,
    icon: Icons.movie_outlined,
    mode: ContentMode.anime,
    kind: StreamKind.movie,
  ),
  (
    label: (c) => c.l10n.modeManga,
    icon: Icons.auto_stories_outlined,
    mode: ContentMode.manga,
    kind: StreamKind.anime,
  ),
  (
    label: (c) => c.l10n.modeNovel,
    icon: Icons.menu_book_outlined,
    mode: ContentMode.novel,
    kind: StreamKind.anime,
  ),
];

IconData iconForMode(ContentMode mode, StreamKind kind) => modeChoices
    .firstWhere(
      (c) => c.mode == mode && (mode != ContentMode.anime || c.kind == kind),
    )
    .icon;

/// The floating bar above the dock. Hidden (and untappable) when [open] is
/// false; slides up when true.
class ModeBar extends StatelessWidget {
  const ModeBar({
    super.key,
    required this.open,
    required this.current,
    required this.onPicked,
  });

  final bool open;
  final (ContentMode, StreamKind) current;

  final void Function(ContentMode mode, StreamKind kind) onPicked;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedSlide(
        offset: open ? Offset.zero : const Offset(0, 0.35),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: open ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          // Same width as the dock on a tablet (520 + its 16 side padding);
          // a phone gets the very same Padding as before.
          child: tabletColumn(
            context,
            maxWidth: 552,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // Match the bottom dock's glass while this selector is visible.
              child: FakeFrost(
                borderRadius: BorderRadius.circular(20),
                opacity: 0.55,
                blur: true,
                blurSigma: 14,
                padding: const EdgeInsets.all(6),
                child: Row(
                  children: [
                    for (final c in modeChoices)
                      Expanded(
                        child: _Choice(
                          label: c.label(context),
                          icon: c.icon,
                          selected:
                              c.mode == current.$1 &&
                              (c.mode != ContentMode.anime ||
                                  c.kind == current.$2),
                          onTap: () => onPicked(c.mode, c.kind),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        // Slimmed from 9/21/4 and a 13pt caption. The layout is unchanged —
        // icon over label, four across — it just stops eating so much of the
        // screen while it is open.
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              // A tighter line box as well as a smaller face: caption's 1.3
              // height was adding more than the font size did.
              style: AppText.caption.copyWith(
                color: color,
                fontSize: 11,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The fixed centre button. Rotates to a ✕ while the bar is open.
class ModeFab extends StatelessWidget {
  const ModeFab({
    super.key,
    required this.open,
    required this.icon,
    required this.onTap,
  });
  final bool open;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(open ? 25 : 17),
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: AnimatedRotation(
          turns: open ? 0.125 : 0,
          duration: const Duration(milliseconds: 220),
          child: Icon(
            open ? Icons.add_rounded : icon,
            color: Colors.black,
            size: 24,
          ),
        ),
      ),
    );
  }
}
