import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Stands in for episode comments until there's a backend. Deliberately quiet —
/// it shouldn't look like something failed to load.
class WatchCommentsPlaceholder extends StatelessWidget {
  const WatchCommentsPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 40, color: AppColors.textTertiary),
            const SizedBox(height: 14),
            Text('Comments are coming',
                style: AppText.headline.copyWith(color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text(
              "You'll be able to talk about each episode here.",
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}
