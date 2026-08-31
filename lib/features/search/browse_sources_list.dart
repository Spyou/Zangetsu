import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/source_switcher.dart';
import '../../l10n/l10n.dart';

/// "Which source do you want to browse?" — the idle state of Search's Sources
/// scope, and the way into one source's own catalogue.
///
/// Reads [categorizedSources] (the same function the Home switcher uses) rather
/// than `SourceRepository.loadedSources`, which narrows by language preference:
/// right for a search fan-out, wrong for a list that claims to show what you
/// have installed.
class BrowseSourcesList extends StatelessWidget {
  const BrowseSourcesList({super.key, required this.onBrowse, this.query = ''});

  final void Function(String sourceId, String name) onBrowse;

  /// Filters the rows by source name (label, and repo tag when present) —
  /// case-insensitive substring, empty = show everything. This narrows which
  /// installed sources are listed; it never touches content search.
  final String query;

  @override
  Widget build(BuildContext context) {
    final b = categorizedSources();
    final q = query.trim().toLowerCase();
    bool matches(({String id, String label, String? repo}) s) =>
        q.isEmpty ||
        s.label.toLowerCase().contains(q) ||
        (s.repo?.toLowerCase().contains(q) ?? false);

    final groups = <(String, List<({String id, String label, String? repo})>)>[
      (context.l10n.anime, b.anime.where(matches).toList()),
      (context.l10n.moviesSeries, b.movies.where(matches).toList()),
      (context.l10n.modeManga, b.manga.where(matches).toList()),
      (context.l10n.modeNovel, b.novel.where(matches).toList()),
    ].where((g) => g.$2.isNotEmpty).toList();

    if (groups.isEmpty) {
      final nothingInstalled =
          b.anime.isEmpty && b.movies.isEmpty && b.manga.isEmpty && b.novel.isEmpty;
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          nothingInstalled
              ? context.l10n.noSourcesInstalled
              : context.l10n.noMatchesFound,
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final (title, rows) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Text(
              title.toUpperCase(),
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final s in rows)
            ListTile(
              title: Text(
                s.label,
                style: AppText.body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: (s.repo == null || s.repo!.isEmpty)
                  ? null
                  : Text(s.repo!, style: AppText.caption),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textTertiary,
              ),
              onTap: () => onBrowse(s.id, s.label),
            ),
        ],
      ],
    );
  }
}
