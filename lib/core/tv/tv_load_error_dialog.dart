import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_focusable.dart';

/// TV-sized alert when an episode stream fails to resolve or start.
///
/// Ten-foot UI: large type, wide card, and a single autofocused OK so the
/// remote can dismiss it without hunting. Phone layouts never call this.
Future<void> showTvPlaybackLoadError(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 96, vertical: 64),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 560, maxWidth: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Couldn't load this episode",
                style: AppText.largeTitle.copyWith(fontSize: 28),
              ),
              const SizedBox(height: 16),
              Text(
                'There was an issue loading this content. If this continues, '
                'try changing sources.',
                style: AppText.body.copyWith(
                  fontSize: 18,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              Align(
                alignment: Alignment.centerRight,
                child: TvFocusable(
                  scale: 1.0,
                  autofocus: true,
                  variant: TvFocusVariant.pill,
                  onTap: () => Navigator.pop(ctx),
                  semanticLabel: 'OK',
                  builder: (focused) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: focused ? Colors.white : AppColors.accent,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 36,
                        vertical: 14,
                      ),
                      child: Text(
                        'OK',
                        style: AppText.headline.copyWith(
                          fontSize: 18,
                          color: focused ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
