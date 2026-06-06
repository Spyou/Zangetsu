import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/search_history.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/media_info_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../auth/auth_screens.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import '../search/bloc/search_bloc.dart';
import '../search/bloc/search_event.dart';
import '../search/bloc/search_state.dart';

/// Dedicated search screen pushed from the Home header search icon.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key, this.initialQuery, this.showBack = true});

  final String? initialQuery;

  /// When [false] the screen is embedded as a bottom-nav tab and the back
  /// arrow is hidden (also suppresses autofocus on launch).
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final bloc = SearchBloc(
          repo: sl<SourceRepository>(),
          history: sl<SearchHistory>(),
        )..add(const SearchStarted());
        final q = initialQuery?.trim();
        if (q != null && q.isNotEmpty) bloc.add(SearchQueryChanged(q));
        return bloc;
      },
      child: _SearchView(initialQuery: initialQuery, showBack: showBack),
    );
  }
}

class _SearchView extends StatefulWidget {
  const _SearchView({this.initialQuery, required this.showBack});

  final String? initialQuery;
  final bool showBack;

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  late final TextEditingController _controller;
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();
  final _history = sl<SearchHistory>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Query helpers ─────────────────────────────────────────────────────────
  void _runQuery(String q) {
    _controller.value = TextEditingValue(
      text: q,
      selection: TextSelection.collapsed(offset: q.length),
    );
    context.read<SearchBloc>().add(SearchQueryChanged(q));
  }

  void _clear() {
    _controller.clear();
    context.read<SearchBloc>().add(const SearchQueryChanged(''));
  }

  String _typeLabel(ProviderType t) =>
      t == ProviderType.movie ? 'Movie' : 'Anime';

  Future<MediaDetail?> _detailOf(String url, String sourceId) async {
    try {
      return await _repo.detail(url, sourceId: sourceId);
    } catch (_) {
      return null;
    }
  }

  List<String> _tagsFor(MediaItem m) {
    final t = <String>[];
    if ((m.dubCount ?? 0) > 0) t.add('DUB');
    if ((m.subCount ?? 0) > 0 && t.length < 2) t.add('SUB');
    if (t.isEmpty && m.type == ProviderType.movie) t.add('MOVIE');
    return t;
  }

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _play(MediaItem item) async {
    final category = sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: item.sourceId,
          episodesResolver: () =>
              _repo.episodes(item.url, sourceId: item.sourceId),
          resume: sl<ResumeStore>(),
          resolveSources: (u) => _repo.sources(u, sourceId: item.sourceId),
          history: sl<WatchHistory>(),
          showTitle: item.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          showUrl: item.url,
          category: category,
          malId: item.malId,
          scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _showInfo(MediaItem item) {
    showMediaInfoSheet(
      context,
      title: item.title,
      englishTitle: item.englishTitle,
      cover: item.cover,
      headers: item.coverHeaders,
      typeLabel: _typeLabel(item.type),
      subCount: item.subCount,
      dubCount: item.dubCount,
      detail: _detailOf(item.url, item.sourceId),
      inMyList: _myList.contains(item),
      onPlay: () => _play(item),
      onOpenDetail: () => _openDetail(item),
      onToggleMyList: () async {
        if (!requireLogin(context, action: 'add to My List')) {
          return _myList.contains(item);
        }
        await _myList.toggle(item);
        if (mounted) setState(() {});
        return _myList.contains(item);
      },
    );
  }

  // ── Sort sheet ────────────────────────────────────────────────────────────
  void _openSortSheet(BuildContext context) {
    final bloc = context.read<SearchBloc>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => BlocProvider.value(
        value: bloc,
        child: BlocBuilder<SearchBloc, SearchState>(
          builder: (ctx, state) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  for (final opt in SearchSort.values)
                    InkWell(
                      onTap: () {
                        ctx.read<SearchBloc>().add(SearchSortChanged(opt));
                        Navigator.pop(ctx);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                opt.label,
                                style: AppText.body.copyWith(
                                  color: state.sort == opt
                                      ? AppColors.textPrimary
                                      : AppColors.textSecondary,
                                  fontWeight: state.sort == opt
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (state.sort == opt)
                              const Icon(Icons.check_rounded,
                                  size: 20, color: AppColors.accent),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cellW = (mq.size.width - 40 - 24) / 3;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _searchBar(),
            const SizedBox(height: 14),
            // History-based type-ahead: matching past searches while one runs.
            BlocBuilder<SearchBloc, SearchState>(
              buildWhen: (p, c) => p.status != c.status,
              builder: (context, state) {
                if (state.status != SearchStatus.loading) {
                  return const SizedBox.shrink();
                }
                final q = _controller.text.trim().toLowerCase();
                if (q.isEmpty) return const SizedBox.shrink();
                final matches = _history
                    .recent()
                    .where((e) {
                      final l = e.toLowerCase();
                      return l != q && l.contains(q);
                    })
                    .take(5)
                    .toList();
                if (matches.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SizedBox(
                    height: 34,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final m in matches)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _suggestionChip(m),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            // Source-filter chips appear once cross-source results land.
            BlocBuilder<SearchBloc, SearchState>(
              buildWhen: (p, c) =>
                  p.groups != c.groups ||
                  p.sourceFilter != c.sourceFilter ||
                  p.status != c.status,
              builder: (context, state) {
                if (state.status != SearchStatus.success ||
                    state.groups.length < 2) {
                  return const SizedBox.shrink();
                }
                return _filterChips(state);
              },
            ),
            Expanded(
              child: BlocBuilder<SearchBloc, SearchState>(
                builder: (context, state) {
                  switch (state.status) {
                    case SearchStatus.idle:
                      return _idleView(state);
                    case SearchStatus.loading:
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: SkeletonGrid(),
                      );
                    case SearchStatus.error:
                      return const EmptyState(
                        icon: Icons.error_outline,
                        message: 'Search failed — try again',
                      );
                    case SearchStatus.success:
                      final items = state.visibleResults;
                      if (items.isEmpty) {
                        return EmptyState(
                          icon: Icons.search_off,
                          message: 'No results for "${state.query}"',
                        );
                      }
                      return _resultsGrid(items, cellW);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Search bar ────────────────────────────────────────────────────────────
  Widget _searchBar() {
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.showBack ? 4 : 16, 12, 16, 0),
      child: Row(
        children: [
          if (widget.showBack)
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new,
                  color: Colors.white, size: 20),
              onPressed: () => Navigator.pop(context),
              tooltip: 'Back',
            ),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const Icon(Icons.search,
                      size: 20, color: AppColors.textTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: widget.showBack,
                      textInputAction: TextInputAction.search,
                      onChanged: (text) => context
                          .read<SearchBloc>()
                          .add(SearchQueryChanged(text)),
                      onSubmitted: (text) => context
                          .read<SearchBloc>()
                          .add(SearchQueryChanged(text)),
                      style: AppText.body.copyWith(color: AppColors.textPrimary),
                      cursorColor: AppColors.accent,
                      decoration: const InputDecoration(
                        hintText: 'Search…',
                        hintStyle: AppText.body,
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  // Clear button (only when there's text).
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            icon: const Icon(Icons.close_rounded,
                                size: 18, color: AppColors.textTertiary),
                            tooltip: 'Clear',
                            onPressed: _clear,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                          ),
                  ),
                  // Sort — tinted coral when sort is not default.
                  BlocBuilder<SearchBloc, SearchState>(
                    buildWhen: (p, c) => p.sort != c.sort,
                    builder: (context, state) => IconButton(
                      icon: Icon(
                        Icons.sort_rounded,
                        size: 20,
                        color: state.sort != SearchSort.bestMatch
                            ? AppColors.accent
                            : AppColors.textTertiary,
                      ),
                      tooltip: 'Sort',
                      onPressed: () => _openSortSheet(context),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Source filter chips ───────────────────────────────────────────────────
  Widget _filterChips(SearchState state) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip(
            label: 'All ${state.totalCount}',
            selected: state.sourceFilter == kAllSources,
            onTap: () => context
                .read<SearchBloc>()
                .add(const SearchSourceFilterChanged(kAllSources)),
          ),
          for (final g in state.groups)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _chip(
                label: '${g.sourceName} ${g.items.length}',
                selected: state.sourceFilter == g.sourceId,
                onTap: () => context
                    .read<SearchBloc>()
                    .add(SearchSourceFilterChanged(g.sourceId)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.surface2,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: AppText.caption.copyWith(
              color: selected ? Colors.white : AppColors.textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  // ── Results grid ──────────────────────────────────────────────────────────
  Widget _resultsGrid(List<MediaItem> items, double cellW) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      cacheExtent: 800,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return PosterCard(
          title: item.title,
          imageUrl: item.cover,
          headers: item.coverHeaders,
          tags: _tagsFor(item),
          cellWidth: cellW,
          onTap: () => _openDetail(item),
          onLongPress: () => _showInfo(item),
        );
      },
    );
  }

  // ── Idle view: recent searches + trending ─────────────────────────────────
  Widget _idleView(SearchState state) {
    final recent = _history.recent();
    final trending = state.trending;

    if (recent.isEmpty && trending.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded, size: 48, color: AppColors.textTertiary),
            SizedBox(height: 12),
            Text('Search for something to watch',
                textAlign: TextAlign.center, style: AppText.body),
          ],
        ),
      );
    }

    final cellW = (MediaQuery.of(context).size.width - 40 - 24) / 3;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (recent.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text('Recent searches', style: AppText.overline),
              ),
              GestureDetector(
                onTap: () async {
                  await _history.clear();
                  if (mounted) setState(() {});
                },
                child: Text(
                  'Clear',
                  style: AppText.caption.copyWith(color: AppColors.accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final q in recent) _recentChip(q)],
          ),
          const SizedBox(height: 24),
        ],
        if (trending.isNotEmpty) ...[
          const Text('Top picks', style: AppText.overline),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.62,
              crossAxisSpacing: 12,
              mainAxisSpacing: 16,
            ),
            itemCount: trending.length,
            itemBuilder: (context, i) {
              final item = trending[i];
              return PosterCard(
                title: item.title,
                imageUrl: item.cover,
                headers: item.coverHeaders,
                tags: _tagsFor(item),
                cellWidth: cellW,
                onTap: () => _openDetail(item),
                onLongPress: () => _showInfo(item),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _suggestionChip(String q) {
    return Center(
      child: GestureDetector(
        onTap: () => _runQuery(q),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history_rounded,
                  size: 14, color: AppColors.textTertiary),
              const SizedBox(width: 6),
              Text(q,
                  style:
                      AppText.caption.copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recentChip(String q) {
    return GestureDetector(
      onTap: () => _runQuery(q),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history_rounded,
                size: 15, color: AppColors.textTertiary),
            const SizedBox(width: 6),
            Text(q,
                style: AppText.caption.copyWith(color: AppColors.textSecondary)),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () async {
                await _history.remove(q);
                if (mounted) setState(() {});
              },
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close_rounded,
                    size: 14, color: AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
