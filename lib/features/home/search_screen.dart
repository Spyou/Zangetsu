import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/search_history.dart';
import '../../core/playback/search_prefs.dart';
import '../../core/playback/search_source_prefs.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/media_info_sheet.dart';
import '../../core/ui/row_skeleton.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../auth/auth_screens.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import 'search_screen_tv.dart';
import 'see_all_screen.dart';
import '../search/bloc/search_bloc.dart';
import '../search/bloc/search_event.dart';
import '../search/bloc/search_state.dart';

/// Dedicated search screen pushed from the Home header search icon.
class SearchScreen extends StatelessWidget {
  const SearchScreen({
    super.key,
    this.initialQuery,
    this.showBack = true,
    this.focusSignal,
  });

  final String? initialQuery;

  /// When [false] the screen is embedded as a bottom-nav tab and the back
  /// arrow is hidden (also suppresses autofocus on launch).
  final bool showBack;

  /// Bumped by the shell each time the Search tab is selected, so the embedded
  /// tab can auto-focus its field without stealing focus while it sits idle in
  /// the IndexedStack. Null for the pushed (showBack) variant.
  final ValueListenable<int>? focusSignal;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final bloc = SearchBloc(
          repo: sl<SourceRepository>(),
          history: sl<SearchHistory>(),
        )..add(const SearchStarted());
        final q = initialQuery?.trim();
        // An initial query (e.g. "see all results" from Home) runs the full
        // search straight away rather than waiting for the user to type.
        if (q != null && q.isNotEmpty) bloc.add(SearchRunRequested(q));
        return bloc;
      },
      // On Android TV, hand off to the D-pad-optimised layout. The BlocProvider
      // above is still the provider for both paths — SearchScreenTv reads the
      // same SearchBloc from context, so no duplication of bloc creation.
      child: sl<AppMode>().isTv
          ? SearchScreenTv(initialQuery: initialQuery)
          : _SearchView(
              initialQuery: initialQuery,
              showBack: showBack,
              focusSignal: focusSignal,
            ),
    );
  }
}

class _SearchView extends StatefulWidget {
  const _SearchView({
    this.initialQuery,
    required this.showBack,
    this.focusSignal,
  });

  final String? initialQuery;
  final bool showBack;
  final ValueListenable<int>? focusSignal;

  @override
  State<_SearchView> createState() => _SearchViewState();
}

/// Max posters shown in a per-source section before it collapses to a "See all"
/// link. Picked to fill a few grid rows / a comfortable horizontal row without
/// the section dominating the screen.
const int _kSourcePreviewCap = 12;

class _SearchViewState extends State<_SearchView> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();
  final _history = sl<SearchHistory>();
  final _searchPrefs = sl<SearchPrefs>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery ?? '');
    widget.focusSignal?.addListener(_onFocusSignal);
  }

  /// Focus the field when the Search tab is (re)selected so the keyboard is
  /// ready. Defers a frame so it runs after the IndexedStack reveals the tab.
  void _onFocusSignal() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.focusSignal?.removeListener(_onFocusSignal);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Query helpers ─────────────────────────────────────────────────────────
  /// Fills the field with [q] and runs the full search now (suggestion /
  /// recent / submit). Also dismisses the keyboard so results are unobstructed.
  void _runQuery(String q) {
    _controller.value = TextEditingValue(
      text: q,
      selection: TextSelection.collapsed(offset: q.length),
    );
    FocusScope.of(context).unfocus();
    context.read<SearchBloc>().add(SearchRunRequested(q));
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
      DetailScreen.route(item),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Opens the full-grid view of ONE source's complete results for the current
  /// query. Reuses the home "See All" screen (with search-style poster tags) so
  /// tapping a result opens its Detail exactly like the search grid.
  void _openSourceSeeAll(SourceResultGroup g) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeeAllScreen(
          title: g.sourceName,
          items: g.items,
          tagsFor: _tagsFor,
          onTap: _openDetail,
          onLongPress: _showInfo,
        ),
      ),
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
          resolveSources: (u) =>
              _repo.sources(u, sourceId: item.sourceId, fast: true),
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

  // ── Filters (content type + genre + decade + sources) ───────────────────────
  /// Opens the CloudStream-style filter sheet: content type + genre + decade,
  /// plus the categorised "search in these sources" list. Apply re-runs the
  /// current query so toggles take effect immediately.
  Future<void> _openFilterSheet(BuildContext context) async {
    final bloc = context.read<SearchBloc>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => BlocProvider.value(
        value: bloc,
        child: const _SearchFilterSheet(),
      ),
    );
    // Re-run so source toggles drop out / reappear (content-type filtering is
    // applied client-side and updates live via the bloc, but a fresh run also
    // picks up newly-enabled sources).
    if (bloc.state.query.trim().isNotEmpty) {
      bloc.add(const SearchSubmitted());
    }
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
            const SizedBox(height: 12),
            _scopePill(),
            const SizedBox(height: 10),
            // Per-source result chips — only meaningful when searching all
            // sources, so they're hidden in current-source-only mode (one
            // source can't be filtered down further).
            BlocBuilder<SearchBloc, SearchState>(
              buildWhen: (p, c) =>
                  p.groups != c.groups ||
                  p.sourceFilter != c.sourceFilter ||
                  p.currentSourceOnly != c.currentSourceOnly ||
                  p.contentFilter != c.contentFilter ||
                  p.genreFilter != c.genreFilter ||
                  p.decadeFilter != c.decadeFilter ||
                  p.suggestions != c.suggestions ||
                  p.status != c.status,
              builder: (context, state) {
                final showingSuggestions = state.status != SearchStatus.success &&
                    state.suggestions.isNotEmpty;
                if (state.currentSourceOnly ||
                    showingSuggestions ||
                    state.status != SearchStatus.success ||
                    state.visibleGroups.length < 2) {
                  return const SizedBox.shrink();
                }
                return _filterChips(state);
              },
            ),
            Expanded(
              child: BlocBuilder<SearchBloc, SearchState>(
                builder: (context, state) {
                  // While typing (before a search runs), show the live
                  // suggestion list instead of the idle/results body.
                  if (state.status != SearchStatus.success &&
                      state.suggestions.isNotEmpty) {
                    return _suggestionList(state.suggestions);
                  }
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
                      return _resultsBody(state, cellW);
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
                  const SizedBox(width: 4),
                  // Tappable magnifier — runs the full search (same as Enter).
                  IconButton(
                    icon: const Icon(Icons.search,
                        size: 20, color: AppColors.textTertiary),
                    tooltip: 'Search',
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      context
                          .read<SearchBloc>()
                          .add(SearchRunRequested(_controller.text));
                    },
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus: widget.showBack,
                      textInputAction: TextInputAction.search,
                      // Typing only updates suggestions — it never starts the
                      // heavy multi-source search.
                      onChanged: (text) => context
                          .read<SearchBloc>()
                          .add(SearchQueryChanged(text)),
                      // Enter / keyboard "search" runs the full search.
                      onSubmitted: (text) {
                        FocusScope.of(context).unfocus();
                        context
                            .read<SearchBloc>()
                            .add(SearchRunRequested(text));
                      },
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
                  // Filters — content type + genre + decade + which sources to
                  // search. Tinted coral when any filter is active.
                  BlocBuilder<SearchBloc, SearchState>(
                    buildWhen: (p, c) =>
                        p.contentFilter != c.contentFilter ||
                        p.genreFilter != c.genreFilter ||
                        p.decadeFilter != c.decadeFilter ||
                        p.currentSourceOnly != c.currentSourceOnly,
                    builder: (context, state) => ListenableBuilder(
                      listenable: sl<SearchSourcePrefs>(),
                      builder: (context, _) {
                        // Source excludes only count as an active filter when
                        // actually fanning out to all sources.
                        final active = state.hasActiveFilter ||
                            (!state.currentSourceOnly &&
                                sl<SearchSourcePrefs>().excluded.isNotEmpty);
                        return IconButton(
                          icon: Icon(
                            Icons.tune_rounded,
                            size: 20,
                            color: active
                                ? AppColors.accent
                                : AppColors.textTertiary,
                          ),
                          tooltip: 'Filters',
                          onPressed: () => _openFilterSheet(context),
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 36, minHeight: 36),
                        );
                      },
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

  // ── Search scope pill (current source ⇄ all sources) ──────────────────────
  /// CloudStream-style scope toggle: tap to flip between searching ONLY the
  /// active Home source and fanning out to every enabled source. Lives just
  /// under the bar so it reads as a search-wide control, before the per-source
  /// chips. Follows the active source live via [ActiveSourceCubit].
  Widget _scopePill() {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) => p.currentSourceOnly != c.currentSourceOnly,
      builder: (context, state) {
        final currentOnly = state.currentSourceOnly;
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) {
            final src = _repo.displayName(activeId);
            final label = currentOnly ? 'Only $src' : 'All sources';
            // Spell out what the toggle does so it isn't a mystery chip.
            final hint = currentOnly
                ? 'Tap to search all sources instead'
                : 'Tap to search only $src';
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => context
                        .read<SearchBloc>()
                        .add(SearchScopeChanged(!currentOnly)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: currentOnly
                            ? AppColors.accentSoft
                            : AppColors.surface2,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: currentOnly
                              ? AppColors.accent
                              : AppColors.hairline,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            currentOnly
                                ? Icons.adjust_rounded
                                : Icons.public_rounded,
                            size: 15,
                            color: currentOnly
                                ? AppColors.accent
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: AppText.caption.copyWith(
                              color: currentOnly
                                  ? AppColors.accent
                                  : AppColors.textSecondary,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.swap_horiz_rounded,
                            size: 15,
                            color: currentOnly
                                ? AppColors.accent
                                : AppColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 5),
                    child: Text(
                      hint,
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                        fontSize: 11.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ── Source filter chips ───────────────────────────────────────────────────
  Widget _filterChips(SearchState state) {
    final groups = state.visibleGroups;
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
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _chip(
                label: '${g.sourceName} ${state.countFor(g)}',
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

  // ── Results body (grouped per source, layout-aware) ─────────────────────────
  Widget _resultsBody(SearchState state, double cellW) {
    final groups = state.sortedVisibleGroups;

    // Sources still loading: those switched on for search that haven't returned
    // a (visible) group yet. Show a skeleton section for each while they stream.
    // Only when viewing all sources — a selected source chip means the user has
    // narrowed to one, so other sources' skeletons would be noise.
    final prefs = sl<SearchSourcePrefs>();
    final landed = {for (final g in state.groups) g.sourceId};
    // Current-source-only mode queries a single source, so there are never
    // other sources still streaming in — no skeleton sections.
    final pending = (state.currentSourceOnly || state.sourceFilter != kAllSources)
        ? const <({String id, String name})>[]
        : _repo.loadedSources
            .where((s) => prefs.isIncluded(s.id) && !landed.contains(s.id))
            .toList();
    final stillLoading = pending.isNotEmpty;

    if (groups.isEmpty && !stillLoading) {
      return _noResults(state);
    }

    // A single-source view reads best as the dense flat grid rather than one
    // lonely section: either an explicit chip selection, or only one source
    // returned and nothing else is still streaming in.
    final singleSource = state.sourceFilter != kAllSources ||
        (groups.length == 1 && !stillLoading);
    final layout = _searchPrefs.layout;

    // A single source always reads best as the full grid — a lone horizontal
    // row is cramped — regardless of the All-view layout setting.
    if (singleSource) {
      return _resultsGrid(state.visibleResults, cellW);
    }

    return ListView(
      padding: const EdgeInsets.only(top: 6, bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final g in groups) ...[
          if (layout == SearchLayout.horizontal)
            _sourceRow(g, cellW)
          else
            _sourceGrid(g, cellW),
          const SizedBox(height: 18),
        ],
        // Per-source skeletons for sources whose results haven't arrived yet.
        if (stillLoading)
          for (final s in pending) ...[
            _skeletonSection(s.name, layout),
            const SizedBox(height: 18),
          ],
      ],
    );
  }

  /// Section header — "MovieBox · 12" (source name + count under the filters).
  /// When [onSeeAll] is provided a right-aligned "See all ›" link opens that
  /// source's full results (shown only when the section is capped).
  Widget _sectionHeader(String name, int count, {VoidCallback? onSeeAll}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count > 0 ? '$name  ·  $count' : name,
              style: AppText.headline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onSeeAll != null)
            GestureDetector(
              onTap: onSeeAll,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'See all',
                      style: AppText.caption.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        size: 18, color: AppColors.accent),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Horizontal (CloudStream-style) poster row for one source. Capped to
  /// [_kSourcePreviewCap]; the header's "See all" opens the full grid.
  Widget _sourceRow(SourceResultGroup g, double cellW) {
    const itemW = 124.0;
    const itemH = 210.0;
    final overflows = g.items.length > _kSourcePreviewCap;
    final preview = overflows
        ? g.items.take(_kSourcePreviewCap).toList(growable: false)
        : g.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionHeader(g.sourceName, g.items.length,
            onSeeAll: overflows ? () => _openSourceSeeAll(g) : null),
        SizedBox(
          height: itemH,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            cacheExtent: 600,
            itemCount: preview.length,
            itemBuilder: (context, i) {
              final item = preview[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: itemW,
                  child: RepaintBoundary(
                    child: PosterCard(
                      title: item.title,
                      imageUrl: item.cover,
                      headers: item.coverHeaders,
                      tags: _tagsFor(item),
                      cellWidth: itemW,
                      onTap: () => _openDetail(item),
                      onLongPress: () => _showInfo(item),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Vertical grid for one source, under its header. Capped to
  /// [_kSourcePreviewCap]; the header's "See all" opens the full grid.
  Widget _sourceGrid(SourceResultGroup g, double cellW) {
    final overflows = g.items.length > _kSourcePreviewCap;
    final preview = overflows
        ? g.items.take(_kSourcePreviewCap).toList(growable: false)
        : g.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionHeader(g.sourceName, g.items.length,
            onSeeAll: overflows ? () => _openSourceSeeAll(g) : null),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.62,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
          ),
          itemCount: preview.length,
          itemBuilder: (context, i) {
            final item = preview[i];
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
    );
  }

  /// A loading skeleton for a source section that hasn't returned yet.
  Widget _skeletonSection(String name, SearchLayout layout) {
    if (layout == SearchLayout.horizontal) {
      return const RowSkeleton();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionHeader(name, 0),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: SkeletonGrid(),
        ),
      ],
    );
  }

  /// Cleaner no-results state with the searched query echoed back.
  Widget _noResults(SearchState state) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded,
                size: 52, color: AppColors.textTertiary),
            const SizedBox(height: 14),
            Text(
              'No results for “${state.query}”',
              textAlign: TextAlign.center,
              style: AppText.headline,
            ),
            const SizedBox(height: 6),
            Text(
              state.hasActiveFilter
                  ? 'Try clearing your filters or searching a different title.'
                  : 'Check the spelling or try a different title.',
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
            if (state.hasActiveFilter) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  final bloc = context.read<SearchBloc>();
                  bloc
                    ..add(const SearchContentFilterChanged(
                        SearchContentFilter.all))
                    ..add(const SearchGenreFilterChanged(null))
                    ..add(const SearchDecadeFilterChanged(null));
                },
                child: Text(
                  'Clear filters',
                  style: AppText.body.copyWith(color: AppColors.accent),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Flat results grid (single-source / vertical) ──────────────────────────
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

  // ── Type-ahead suggestion list (history + live titles) ────────────────────
  Widget _suggestionList(List<String> suggestions) {
    final history = _history.recent().map((e) => e.toLowerCase()).toSet();
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: suggestions.length,
      itemBuilder: (context, i) {
        final s = suggestions[i];
        final fromHistory = history.contains(s.toLowerCase());
        return _suggestionRow(s, fromHistory: fromHistory);
      },
    );
  }

  Widget _suggestionRow(String q, {required bool fromHistory}) {
    return InkWell(
      onTap: () => _runQuery(q),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Icon(
              fromHistory ? Icons.history_rounded : Icons.search_rounded,
              size: 18,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                q,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Tap to fill the field without running yet (CloudStream-style).
            GestureDetector(
              onTap: () {
                _controller.value = TextEditingValue(
                  text: q,
                  selection: TextSelection.collapsed(offset: q.length),
                );
                context.read<SearchBloc>().add(SearchQueryChanged(q));
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.north_west_rounded,
                    size: 16, color: AppColors.textTertiary),
              ),
            ),
          ],
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

/// CloudStream-style filter sheet: content type + genre + decade selectors on
/// top of the categorised "search in these sources" list. Content type filters
/// results live (via the bloc); genre/decade are best-effort (see [SearchMeta]).
/// Source toggles are search-only and every source is on by default. "Done"
/// closes the sheet and the caller re-runs the current query.
class _SearchFilterSheet extends StatelessWidget {
  const _SearchFilterSheet();

  @override
  Widget build(BuildContext context) {
    final buckets = categorizedSources();
    final prefs = sl<SearchSourcePrefs>();
    final sections = <({String title, List<({String id, String label, String? repo})> rows})>[
      if (buckets.anime.isNotEmpty) (title: 'Anime', rows: buckets.anime),
      if (buckets.movies.isNotEmpty)
        (title: 'Movies & Series', rows: buckets.movies),
      if (buckets.nsfw.isNotEmpty) (title: 'NSFW', rows: buckets.nsfw),
    ];
    final allIds = [for (final s in sections) ...s.rows.map((r) => r.id)];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.fromLTRB(0, 12, 0, 12),
              decoration: BoxDecoration(
                color: AppColors.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Filters', style: AppText.headline),
                  ),
                  BlocBuilder<SearchBloc, SearchState>(
                    buildWhen: (p, c) =>
                        p.contentFilter != c.contentFilter ||
                        p.genreFilter != c.genreFilter ||
                        p.decadeFilter != c.decadeFilter ||
                        p.currentSourceOnly != c.currentSourceOnly,
                    builder: (context, state) {
                      final canReset = state.hasActiveFilter ||
                          (!state.currentSourceOnly &&
                              prefs.excluded.isNotEmpty);
                      if (!canReset) return const SizedBox.shrink();
                      return TextButton(
                        onPressed: () {
                          if (!state.currentSourceOnly) {
                            prefs.setManyIncluded(allIds, true);
                          }
                          context.read<SearchBloc>()
                            ..add(const SearchContentFilterChanged(
                                SearchContentFilter.all))
                            ..add(const SearchGenreFilterChanged(null))
                            ..add(const SearchDecadeFilterChanged(null));
                        },
                        child: Text(
                          'Reset',
                          style:
                              AppText.body.copyWith(color: AppColors.accent),
                        ),
                      );
                    },
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Done',
                      style: AppText.body.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListenableBuilder(
                listenable: prefs,
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    _contentTypeSelector(context),
                    _genreSelector(context),
                    _decadeSelector(context),
                    // The "search in these sources" list only matters when
                    // searching all sources — in current-source-only mode there
                    // is just one source, so it's hidden.
                    if (!context.read<SearchBloc>().state.currentSourceOnly)
                      if (sections.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 28),
                          child: Center(
                            child: Text('No sources installed',
                                style: AppText.body),
                          ),
                        )
                      else ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
                          child: Text(
                            'SEARCH IN SOURCES',
                            style: AppText.caption.copyWith(
                              color: AppColors.textTertiary,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        for (final sec in sections) ...[
                          _categoryHeader(prefs, sec.title, sec.rows),
                          for (final r in sec.rows) _sourceRow(prefs, r),
                        ],
                      ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A small uppercase section label used above each filter group.
  Widget _filterLabel(String text) {
    return Text(
      text,
      style: AppText.caption.copyWith(
        color: AppColors.textTertiary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );
  }

  /// A selectable pill (chip) used across the filter selectors.
  Widget _pill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
    );
  }

  /// The content-type segmented selector, wired to the bloc so the results
  /// filter updates the moment a chip is tapped.
  Widget _contentTypeSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('CONTENT TYPE'),
          const SizedBox(height: 10),
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (p, c) => p.contentFilter != c.contentFilter,
            builder: (context, state) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in SearchContentFilter.values)
                  _pill(
                    label: f.label,
                    selected: state.contentFilter == f,
                    onTap: () => context
                        .read<SearchBloc>()
                        .add(SearchContentFilterChanged(f)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// Best-effort genre keyword selector. "Any" clears it. Items whose titles
  /// don't mention the keyword pass through unless a specific genre is chosen.
  Widget _genreSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('GENRE'),
          const SizedBox(height: 10),
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (p, c) => p.genreFilter != c.genreFilter,
            builder: (context, state) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill(
                  label: 'Any',
                  selected: state.genreFilter == null,
                  onTap: () => context
                      .read<SearchBloc>()
                      .add(const SearchGenreFilterChanged(null)),
                ),
                for (final g in SearchMeta.genres)
                  _pill(
                    label: g,
                    selected: state.genreFilter == g,
                    onTap: () {
                      final next = state.genreFilter == g ? null : g;
                      context
                          .read<SearchBloc>()
                          .add(SearchGenreFilterChanged(next));
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// Best-effort decade selector keyed off a title-parsed year. "Any" clears
  /// it. Items without a parseable year pass through.
  Widget _decadeSelector(BuildContext context) {
    // Offer the current decade back to the 1980s.
    final nowDecade = (DateTime.now().year ~/ 10) * 10;
    final decades = [
      for (var d = nowDecade; d >= 1980; d -= 10) d,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('DECADE'),
          const SizedBox(height: 10),
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (p, c) => p.decadeFilter != c.decadeFilter,
            builder: (context, state) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill(
                  label: 'Any',
                  selected: state.decadeFilter == null,
                  onTap: () => context
                      .read<SearchBloc>()
                      .add(const SearchDecadeFilterChanged(null)),
                ),
                for (final d in decades)
                  _pill(
                    label: "${d}s",
                    selected: state.decadeFilter == d,
                    onTap: () {
                      final next = state.decadeFilter == d ? null : d;
                      context
                          .read<SearchBloc>()
                          .add(SearchDecadeFilterChanged(next));
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _categoryHeader(
    SearchSourcePrefs prefs,
    String title,
    List<({String id, String label, String? repo})> rows,
  ) {
    final ids = rows.map((r) => r.id).toList();
    final onCount = ids.where(prefs.isIncluded).length;
    final allOn = onCount == ids.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${title.toUpperCase()}  ·  $onCount/${ids.length}',
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          TextButton(
            onPressed: () => prefs.setManyIncluded(ids, !allOn),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              allOn ? 'Turn all off' : 'Turn all on',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceRow(SearchSourcePrefs prefs, ({String id, String label, String? repo}) r) {
    final on = prefs.isIncluded(r.id);
    return InkWell(
      onTap: () => prefs.setIncluded(r.id, !on),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                r.label,
                style: AppText.body.copyWith(
                  color: on ? AppColors.textPrimary : AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Switch.adaptive(
              value: on,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => prefs.setIncluded(r.id, v),
            ),
          ],
        ),
      ),
    );
  }
}
