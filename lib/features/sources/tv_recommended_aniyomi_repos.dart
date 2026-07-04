import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import 'aniyomi_recommended_repos.dart';
import 'aniyomi_repo_tab.dart' show kAniyomiReposBoxName;

/// The "RECOMMENDED" repo list for the TV add-Aniyomi-repo dialog.
///
/// Mirrors [TvRecommendedCsRepos] exactly but uses [kRecommendedAniyomiRepos]
/// and checks the `'aniyomi_repos'` Hive box to show "Added" labels.  Every
/// row is a [TvFocusable] so it's reachable with the D-pad.  Activating a
/// (not-yet-added) row calls [onPick] with the repo URL.
class TvRecommendedAniyomiRepos extends StatelessWidget {
  const TvRecommendedAniyomiRepos({
    super.key,
    required this.onPick,
    this.autofocusFirst = true,
  });

  /// Called with the chosen repo base URL when a (not-yet-added) row is picked.
  final ValueChanged<String> onPick;

  /// Give the first row initial focus so a recommendation is one OK-press away.
  final bool autofocusFirst;

  bool _isAdded(String url) {
    try {
      if (Hive.isBoxOpen(kAniyomiReposBoxName)) {
        return Hive.box<String>(kAniyomiReposBoxName).values.contains(url);
      }
    } catch (_) {}
    return false;
  }

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
        for (var i = 0; i < kRecommendedAniyomiRepos.length; i++)
          _row(kRecommendedAniyomiRepos[i], autofocus: autofocusFirst && i == 0),
      ],
    );
  }

  Widget _row(
    ({String name, String desc, String url}) repo, {
    required bool autofocus,
  }) {
    final added = _isAdded(repo.url);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TvFocusable(
        scale: 1.0,
        autofocus: autofocus,
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
