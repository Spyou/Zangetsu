import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

enum TitleSearchChoice { search, searchAll }

/// Small centered popup (not a sheet) opened by tapping the detail title.
/// Bouncy pop-in (fade + scale with an overshoot curve). Title + one hint
/// line + two buttons, no input. Returns the choice, or null when dismissed.
///
/// NOTE: built on [showGeneralDialog], not cue's `showCueDialog` — the latter
/// hard-requires MaterialLocalizations, which the detail route doesn't
/// provide (it throws before the popup even opens).
Future<TitleSearchChoice?> showTitleSearchPopup(
  BuildContext context,
  String title,
) {
  return showGeneralDialog<TitleSearchChoice>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.l10n.dismiss,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => _TitleSearchDialog(title: title),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
      );
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _TitleSearchDialog extends StatelessWidget {
  const _TitleSearchDialog({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    // Plain Material 3 basic dialog: headline + one supporting line, actions
    // right-aligned. No input — the tapped title is the query.
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: AppText.title.copyWith(fontSize: 22),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Search for this title?',
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context)
                            .pop(TitleSearchChoice.searchAll),
                        child: const Text('Search all sources'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => Navigator.of(context)
                            .pop(TitleSearchChoice.search),
                        child: const Text('Search'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
