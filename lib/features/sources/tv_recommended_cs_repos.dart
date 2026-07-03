import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import 'sources_screen.dart' show kRecommendedCsRepos;

/// The "RECOMMENDED" repo list for the TV add-CloudStream-repo dialogs.
///
/// Mirrors the phone dialog's recommended section (same [kRecommendedCsRepos]
/// data and the same one-tap "add" path), but every row is a [TvFocusable] so
/// it's reachable with the D-pad — the phone version uses touch-only buttons.
/// Activating a row calls [onPick] with the repo URL; the host dialog pops with
/// that URL, taking the identical code path as a manually pasted one.
class TvRecommendedCsRepos extends StatelessWidget {
  const TvRecommendedCsRepos({
    super.key,
    required this.onPick,
    this.autofocusFirst = true,
  });

  /// Called with the chosen repo URL when a (not-yet-added) row is activated.
  final ValueChanged<String> onPick;

  /// Give the first row initial focus so a recommendation is one OK-press away.
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(
          'RECOMMENDED',
          style: AppText.caption.copyWith(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < kRecommendedCsRepos.length; i++)
          _row(kRecommendedCsRepos[i], autofocus: autofocusFirst && i == 0),
      ],
    );
  }

  Widget _row(
    ({String name, String desc, String url}) repo, {
    required bool autofocus,
  }) {
    final added = sl<CloudStreamManager>().hasRepo(repo.url);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TvFocusable(
        scale: 1.0,
        autofocus: autofocus,
        // Already-added repos are inert — the "Added" marker says so.
        onTap: added ? () {} : () => onPick(repo.url),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      repo.name,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(repo.desc, style: AppText.caption),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                added ? 'Added' : 'Add',
                style: AppText.caption.copyWith(
                  color: added ? AppColors.textSecondary : AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
