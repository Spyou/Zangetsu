import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';

typedef ModeChoice = ({String Function(BuildContext) label, IconData icon, ContentMode mode, StreamKind kind});

/// The four things the centre button can switch to. Movie/TV shares the
/// `anime` content mode and differs by [StreamKind].
final List<ModeChoice> modeChoices = [
  (label: (c) => c.l10n.modeAnime, icon: Icons.play_circle_outline_rounded, mode: ContentMode.anime, kind: StreamKind.anime),
  (label: (c) => c.l10n.modeMovieTv, icon: Icons.movie_outlined, mode: ContentMode.anime, kind: StreamKind.movie),
  (label: (c) => c.l10n.modeManga, icon: Icons.auto_stories_outlined, mode: ContentMode.manga, kind: StreamKind.anime),
  (label: (c) => c.l10n.modeNovel, icon: Icons.menu_book_outlined, mode: ContentMode.novel, kind: StreamKind.anime),
];

IconData iconForMode(ContentMode mode, StreamKind kind) => modeChoices
    .firstWhere((c) => c.mode == mode && (mode != ContentMode.anime || c.kind == kind))
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Row(
                    children: [
                      for (final c in modeChoices)
                        Expanded(
                          child: _Choice(
                            choice: c,
                            selected: c.mode == current.$1 &&
                                (c.mode != ContentMode.anime || c.kind == current.$2),
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
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.choice, required this.selected, required this.onTap});
  final ModeChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(choice.icon, size: 21, color: color),
            const SizedBox(height: 4),
            Text(choice.label(context), style: AppText.caption.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// The fixed centre button. Rotates to a ✕ while the bar is open.
class ModeFab extends StatelessWidget {
  const ModeFab({super.key, required this.open, required this.icon, required this.onTap});
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
          boxShadow: [BoxShadow(color: AppColors.accent.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: AnimatedRotation(
          turns: open ? 0.125 : 0,
          duration: const Duration(milliseconds: 220),
          child: Icon(open ? Icons.add_rounded : icon, color: Colors.black, size: 24),
        ),
      ),
    );
  }
}
