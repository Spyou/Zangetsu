import 'package:flutter/material.dart';

import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/source_switcher.dart';
import '../../l10n/l10n.dart';
import '../home/search_screen.dart';
import '../sources/sources_search_field.dart';
import 'browse_source_screen_tv.dart';
import 'browse_sources_list.dart';

/// TV entry for browsing installed sources without changing Home's active source.
class BrowseSourcesScreenTv extends StatefulWidget {
  const BrowseSourcesScreenTv({super.key});

  @override
  State<BrowseSourcesScreenTv> createState() => _BrowseSourcesScreenTvState();
}

class _BrowseSourcesScreenTvState extends State<BrowseSourcesScreenTv> {
  final _controller = TextEditingController();
  String _query = '';
  int _tabIndex = 0;

  static const _kinds = SourceListKind.values;

  ContentMode _modeOf(SourceListKind kind) => switch (kind) {
    SourceListKind.streaming => ContentMode.anime,
    SourceListKind.manga => ContentMode.manga,
    SourceListKind.novel => ContentMode.novel,
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(
          forceSources: true,
          forceMode: _modeOf(_kinds[_tabIndex]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tabLabels = [l10n.modeStreaming, l10n.modeManga, l10n.modeNovel];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 48, 16),
              child: Row(
                children: [
                  const TvBackButton(),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(l10n.sources, style: AppText.largeTitle),
                  ),
                  TvFocusable(
                    variant: TvFocusVariant.float,
                    scale: 1.0,
                    semanticLabel: l10n.search,
                    onTap: _openSearch,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Icon(
                        Icons.search_rounded,
                        size: 26,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Tabs and search on separate rows so D-pad up from the list
            // lands on search (focus only — no IME until OK), then up again
            // to the tabs / Back. Sharing one row made search steal focus
            // geometrically from the first source row.
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 12),
              child: Row(
                children: [
                  for (var i = 0; i < tabLabels.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    _BrowseTvTabChip(
                      key: ValueKey('browse-sources-tab-$i'),
                      title: tabLabels[i],
                      selected: _tabIndex == i,
                      autofocus: i == 0,
                      onTap: () => setState(() => _tabIndex = i),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
              child: SourcesSearchField(
                controller: _controller,
                hint: l10n.searchSources,
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
            Expanded(
              child: _BrowseSourcesListTv(
                kind: _kinds[_tabIndex],
                query: _query,
                onBrowse: (id, name) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        BrowseSourceScreenTv(sourceId: id, title: name),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Focusable kind-tab chip — D-pad stand-in for a [TabBar].
class _BrowseTvTabChip extends StatelessWidget {
  const _BrowseTvTabChip({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      // Poster-style white outline; no scale so row clip won't shave it.
      variant: TvFocusVariant.float,
      scale: 1.0,
      borderRadius: 20,
      autofocus: autofocus,
      onTap: onTap,
      semanticLabel: title,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.18)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text(
            title,
            style: AppText.headline.copyWith(
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowseSourcesListTv extends StatelessWidget {
  const _BrowseSourcesListTv({
    required this.onBrowse,
    required this.kind,
    this.query = '',
  });

  final void Function(String sourceId, String name) onBrowse;
  final String query;
  final SourceListKind kind;

  @override
  Widget build(BuildContext context) {
    final b = categorizedSources();
    final q = query.trim().toLowerCase();
    bool matches(({String id, String label, String? repo}) s) =>
        q.isEmpty ||
        s.label.toLowerCase().contains(q) ||
        (s.repo?.toLowerCase().contains(q) ?? false);

    final showStreaming = kind == SourceListKind.streaming;
    final showManga = kind == SourceListKind.manga;
    final showNovel = kind == SourceListKind.novel;

    final groups = <(String, List<({String id, String label, String? repo})>)>[
      if (showStreaming) (context.l10n.anime, b.anime.where(matches).toList()),
      if (showStreaming)
        (context.l10n.moviesSeries, b.movies.where(matches).toList()),
      if (showManga) (context.l10n.modeManga, b.manga.where(matches).toList()),
      if (showNovel) (context.l10n.modeNovel, b.novel.where(matches).toList()),
    ].where((g) => g.$2.isNotEmpty).toList();

    if (groups.isEmpty) {
      final nothingInstalled =
          (!showStreaming || (b.anime.isEmpty && b.movies.isEmpty)) &&
          (!showManga || b.manga.isEmpty) &&
          (!showNovel || b.novel.isEmpty);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Text(
            nothingInstalled
                ? context.l10n.noSourcesInstalled
                : context.l10n.noMatchesFound,
            style: AppText.headline.copyWith(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
      children: [
        for (final (title, rows) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Text(title, style: AppText.headline),
          ),
          for (final s in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: TvListFocusable(
                onTap: () => onBrowse(s.id, s.label),
                semanticLabel: s.label,
                child: ExcludeSemantics(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.label,
                                style: AppText.body,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (s.repo != null && s.repo!.isNotEmpty)
                                Text(s.repo!, style: AppText.caption),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: AppColors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
