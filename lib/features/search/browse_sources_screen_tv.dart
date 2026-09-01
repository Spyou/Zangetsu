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
import 'browse_source_screen.dart';
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
    final tabLabels = [
      l10n.modeStreaming,
      l10n.modeManga,
      l10n.modeNovel,
    ];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 48, 8),
              child: Row(
                children: [
                  const TvBackButton(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(l10n.sources, style: AppText.largeTitle),
                  ),
                  TvFocusable(
                    variant: TvFocusVariant.float,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 8, 48, 12),
              child: Row(
                children: [
                  for (var i = 0; i < tabLabels.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    TvFocusable(
                      key: ValueKey('browse-sources-tab-$i'),
                      variant: TvFocusVariant.float,
                      borderRadius: 999,
                      onTap: () => setState(() => _tabIndex = i),
                      builder: (focused) {
                        final selected = _tabIndex == i;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? Colors.white
                                : (focused
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : null),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            tabLabels[i],
                            style: TextStyle(
                              color: selected
                                  ? Colors.black
                                  : AppColors.textSecondary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 48, 12),
              child: TextField(
                controller: _controller,
                onChanged: (v) => setState(() => _query = v),
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                cursorColor: AppColors.accent,
                decoration: InputDecoration(
                  hintText: l10n.searchSources,
                  hintStyle: AppText.body,
                  prefixIcon: const Icon(
                    Icons.search,
                    color: AppColors.textTertiary,
                  ),
                  filled: true,
                  fillColor: AppColors.surface2,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            Expanded(
              child: _BrowseSourcesListTv(
                kind: _kinds[_tabIndex],
                query: _query,
                onBrowse: (id, name) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        BrowseSourceScreen(sourceId: id, title: name),
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
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        for (final (title, rows) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(48, 18, 48, 8),
            child: Text(title, style: AppText.headline),
          ),
          for (final s in rows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 2),
              child: TvListFocusable(
                onTap: () => onBrowse(s.id, s.label),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
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
        ],
      ],
    );
  }
}
