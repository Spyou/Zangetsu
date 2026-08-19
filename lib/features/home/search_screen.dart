import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
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
import '../../core/ui/reveal_item.dart';
import '../../core/ui/states.dart';
import '../../core/aniyomi/aniyomi_filters.dart';
import '../../core/mihon/mihon_filters.dart';
import '../aniyomi/aniyomi_filter_sheet.dart';
import '../mihon/mihon_filter_sheet.dart';
import '../auth/auth_screens.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';
import '../sources/zangetsu_sources_screen.dart';
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
          ? SearchScreenTv(
              initialQuery: initialQuery,
              history: sl<SearchHistory>(),
            )
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

class _SearchViewState extends State<_SearchView>
    with TickerProviderStateMixin {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();
  final _history = sl<SearchHistory>();
  final _searchPrefs = sl<SearchPrefs>();

  /// Owns the ecosystem [TabBar]'s controller — see [_ecoTabControllerFor].
  TabController? _ecoTabController;
  List<SearchEcosystem> _ecoTabs = const [];

  /// [_repo.loadedSources] narrowed to the active content mode. Anime narrows
  /// too — it used to short-circuit to the unfiltered list, which meant manga
  /// (`mihon:`) and novel (`lnr:`) sources were searched and rendered while in
  /// anime mode. Keep this in step with `SearchBloc._modeSources`, which drives
  /// the actual fan-out; this copy drives the ecosystem tabs and the pending
  /// skeletons, so a mismatch shows up as skeletons for sources that are never
  /// queried.
  List<({String id, String name})> get _modeSources {
    final mode = sl<ContentModeCubit>().state;
    return filterSourcesForMode(
      {for (final s in _repo.loadedSources) s.id: s},
      mode,
      (s) => sourceTypeOf(s.id),
    ).values.toList();
  }

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
    _ecoTabController?.dispose();
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
    Navigator.push(context, DetailScreen.route(item)).then((_) {
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
          // Search results are a fixed, already-fetched set — no pagination.
          onLoadMore: null,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Opens the Aniyomi per-source filter sheet for [sourceId].
  ///
  /// Fetches the filter schema, shows the sheet, and dispatches
  /// [SearchSourceFiltersApplied] with the selection JSON when the user taps
  /// Apply. A brief SnackBar informs the user when the source has no filters.
  Future<void> _openAniFilters(String sourceId) async {
    final stored = context
        .read<SearchBloc>()
        .state
        .aniFiltersBySource[sourceId];
    final List<AniyomiFilter> filters = (stored != null && stored.isNotEmpty)
        ? AniyomiFilters.parse(stored)
        : await _repo.aniFilters(sourceId);
    if (!mounted) return;
    if (filters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This source has no filters')),
      );
      return;
    }
    // Drop focus first. The search field autofocuses on open and keeps focus
    // behind the modal, so the keyboard can reappear over the sheet — which
    // shrinks it to a sliver and then dismisses it, losing the selection.
    FocusScope.of(context).unfocus();
    final result = await showAniyomiFilterSheet(context, filters);
    if (result == null || !mounted) return;
    context.read<SearchBloc>().add(
      SearchSourceFiltersApplied(
        sourceId,
        AniyomiFilters.toSelectionJson(result),
      ),
    );
  }

  /// Mihon twin of [_openAniFilters] — same flow, [MihonFilter] types and
  /// `_repo.mihonFilters`/`showMihonFilterSheet` instead of the Aniyomi ones.
  Future<void> _openMihonFilters(String sourceId) async {
    final stored = context
        .read<SearchBloc>()
        .state
        .mihonFiltersBySource[sourceId];
    final List<MihonFilter> filters = (stored != null && stored.isNotEmpty)
        ? MihonFilters.parse(stored)
        : await _repo.mihonFilters(sourceId);
    if (!mounted) return;
    if (filters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This source has no filters')),
      );
      return;
    }
    // Drop focus first — see [_openAniFilters] for why.
    FocusScope.of(context).unfocus();
    final result = await showMihonFilterSheet(context, filters);
    if (result == null || !mounted) return;
    context.read<SearchBloc>().add(
      SearchSourceFiltersApplied(sourceId, MihonFilters.toSelectionJson(result)),
    );
  }

  Future<void> _play(MediaItem item) async {
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
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

  // ── Filters (sort + content type + audio + genre + sources) ────────────────
  /// Opens the single, merged filter sheet: sort, content type + audio
  /// (anime mode only), genre, plus the categorised "search in these sources"
  /// list behind its own sub-sheet. Apply re-runs the current query so toggles
  /// take effect immediately.
  Future<void> _openFilterSheet(BuildContext context) async {
    final bloc = context.read<SearchBloc>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) =>
          BlocProvider.value(value: bloc, child: const _SearchFilterSheet()),
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
    // sizeOf (not MediaQuery.of) so this rebuilds only when the screen size
    // actually changes, not on every viewInsets change (e.g. every keyboard
    // animation frame).
    final cellW = (MediaQuery.sizeOf(context).width - 40 - 24) / 3;
    // Computed once per outer build, not once per BlocBuilder rebuild below
    // (each fires on every search state emission during a live fan-out).
    final modeSources = _modeSources;

    return Scaffold(
      backgroundColor: AppColors.bg,
      // bottom: false — the shell's floating dock overlays the content
      // (extendBody); a full SafeArea would clip results at the dock's edge.
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _searchBar(),
            const SizedBox(height: 12),
            // Source line — what's being searched, one line of text, tap to
            // open the source picker. Shown idle too, so scope is always known.
            _sourceLine(),
            // Control row — ecosystem tabs (or a result count once scoped to a
            // single source) on the left, sort + filter actions on the right.
            _controlRow(modeSources),
            // Per-source result pills — direct jump to one source's results.
            _sourcePillsRow(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Divider(
                height: 1,
                thickness: 1,
                color: AppColors.hairline,
              ),
            ),
            const SizedBox(height: 6),
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
                      return _resultsBody(state, cellW, modeSources);
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
              icon: const Icon(
                Icons.arrow_back_ios_new,
                color: Colors.white,
                size: 20,
              ),
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
                    icon: const Icon(
                      Icons.search,
                      size: 20,
                      color: AppColors.textTertiary,
                    ),
                    tooltip: 'Search',
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      context.read<SearchBloc>().add(
                        SearchRunRequested(_controller.text),
                      );
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
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
                      onChanged: (text) => context.read<SearchBloc>().add(
                        SearchQueryChanged(text),
                      ),
                      // Enter / keyboard "search" runs the full search.
                      onSubmitted: (text) {
                        FocusScope.of(context).unfocus();
                        context.read<SearchBloc>().add(
                          SearchRunRequested(text),
                        );
                      },
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                      ),
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
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: AppColors.textTertiary,
                            ),
                            tooltip: 'Clear',
                            onPressed: _clear,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
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

  // ── Source line (search scope) ─────────────────────────────────────────────
  /// Replaces the old scope pill + hint sentence: one line of text —
  /// "Searching" + the value — with the value in accent when scoped to a
  /// single source. The whole row opens the source picker sheet. Shown in
  /// idle state too, so the scope is always visible up front. Follows the
  /// active source live via [ActiveSourceCubit], same as the old pill did.
  Widget _sourceLine() {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) => p.currentSourceOnly != c.currentSourceOnly,
      builder: (context, state) {
        final currentOnly = state.currentSourceOnly;
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) {
            final value = currentOnly
                ? _repo.displayName(activeId)
                : 'All sources';
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openSourcePicker(context),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                // Tighter above than below: the search field already carries
                // its own bottom gap, so an even 11/11 left the line sitting
                // lower than it looked like it should.
                padding: const EdgeInsets.only(top: 5, bottom: 11),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.hairline)),
                ),
                child: Row(
                  children: [
                    Text(
                      'Searching',
                      style: AppText.caption.copyWith(fontSize: 12.5),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: currentOnly
                              ? AppColors.accent
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: AppColors.textTertiary,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Bottom sheet listing "All sources" then every source in the current mode
  /// — plain rows, no health/counts. Tapping a row scopes the search to it (or
  /// clears the scope for "All sources") and re-runs, reusing the exact same
  /// [SearchScopeChanged] event the old scope pill dispatched. Switching from
  /// one specific source to another (both already scoped) needs a second,
  /// already-existing event — [SearchScopeChanged] alone no-ops when the
  /// current-source-only flag doesn't change — so that case sets the new
  /// active source then dispatches [SearchSubmitted] to re-run against it.
  void _openSourcePicker(BuildContext context) {
    final bloc = context.read<SearchBloc>();
    final activeCubit = context.read<ActiveSourceCubit>();
    final currentOnly = bloc.state.currentSourceOnly;
    final activeId = activeCubit.state;
    // Active source pinned directly under "All sources" instead of wherever it
    // happens to fall alphabetically — it's the one row you're most likely to
    // want, and with a long source list it was otherwise a scroll away.
    final sources = [..._modeSources]
      ..sort((a, b) {
        if (a.id == activeId) return -1;
        if (b.id == activeId) return 1;
        return 0;
      });
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Search in', style: AppText.headline),
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: sources.length + 1,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.hairline),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return _sourcePickerRow(
                        label: 'All sources',
                        selected: !currentOnly,
                        onTap: () {
                          Navigator.pop(ctx);
                          if (!currentOnly) return;
                          bloc.add(const SearchScopeChanged(false));
                        },
                      );
                    }
                    final s = sources[i - 1];
                    final selected = currentOnly && activeId == s.id;
                    return _sourcePickerRow(
                      label: s.name,
                      selected: selected,
                      // Point out the active source even when the scope is "All
                      // sources" — otherwise nothing on this sheet says which
                      // one "current source" actually means.
                      hint: activeId == s.id ? 'current' : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        if (selected) return;
                        activeCubit.setSource(s.id);
                        // Already scoped (just to a DIFFERENT source): flipping
                        // currentSourceOnly to `true` again would no-op in the
                        // bloc, so re-run explicitly instead of re-toggling scope.
                        if (currentOnly) {
                          bloc.add(const SearchSubmitted());
                        } else {
                          bloc.add(const SearchScopeChanged(true));
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [hint] labels the row without selecting it — used to point out the active
  /// source while the scope is "All sources", so it's clear what "current
  /// source" would switch to.
  Widget _sourcePickerRow({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    String? hint,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppText.body.copyWith(
                  color: selected ? AppColors.accent : AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hint != null && !selected)
              Text(
                hint,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            if (selected)
              Icon(Icons.check_rounded, size: 20, color: AppColors.accent),
          ],
        ),
      ),
    );
  }

  // ── Control row (ecosystem tabs / result count + sort + filter) ────────────
  /// Left: ecosystem tabs when searching all sources (unchanged strip), or a
  /// plain "N results" label once scoped to a single source (tabs are
  /// meaningless with one source). Right: sort + filter actions — relocated
  /// here from the search field so the field itself stays a plain text input.
  /// Unlike the old ecosystem-tabs band, this row never fully collapses: sort
  /// and filter must stay reachable in every state (idle included), exactly as
  /// they were when they lived inside the search bar.
  Widget _controlRow(List<({String id, String name})> modeSources) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(child: _controlRowLeft(modeSources)),
            _sourceFilterAction(),
            _filterAction(),
          ],
        ),
      ),
    );
  }

  Widget _controlRowLeft(List<({String id, String name})> modeSources) {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) =>
          p.status != c.status ||
          p.currentSourceOnly != c.currentSourceOnly ||
          p.ecosystem != c.ecosystem ||
          p.suggestions != c.suggestions ||
          p.groups != c.groups ||
          p.contentFilter != c.contentFilter ||
          p.audioFilter != c.audioFilter ||
          p.genreFilter != c.genreFilter ||
          p.statusFilter != c.statusFilter,
      builder: (context, state) {
        if (state.currentSourceOnly) {
          if (state.status != SearchStatus.success) {
            return const SizedBox.shrink();
          }
          final n = state.totalCount;
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '$n result${n == 1 ? '' : 's'}',
              style: AppText.caption.copyWith(fontSize: 12.5),
            ),
          );
        }
        final showingSuggestions =
            state.status != SearchStatus.success &&
            state.suggestions.isNotEmpty;
        if (showingSuggestions || state.status != SearchStatus.success) {
          return const SizedBox.shrink();
        }
        final tabs = ecosystemTabsFor(modeSources.map((s) => s.id));
        // Fewer than three means "All" plus at most one real ecosystem — the
        // two would show identical results, so the strip is pointless. Show
        // the result count instead of leaving the row blank next to a lone
        // filter icon, which reads as something failing to load. (Manga mode
        // hits this whenever every installed source is a Mihon one.)
        if (tabs.length < 3) {
          final n = state.totalCount;
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '$n result${n == 1 ? '' : 's'}',
              style: AppText.caption.copyWith(fontSize: 12.5),
            ),
          );
        }
        return _ecosystemTabs(state, tabs);
      },
    );
  }

  /// Filters action — sort + content type + audio + genre + which sources to
  /// search, all in one sheet now. Shows a small accent count badge (instead
  /// of only a tint) for how many of those are non-default, so the icon
  /// carries the same signal the old separate sort icon's tint used to.
  Widget _filterAction() {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) =>
          p.sort != c.sort ||
          p.contentFilter != c.contentFilter ||
          p.audioFilter != c.audioFilter ||
          p.genreFilter != c.genreFilter ||
          p.statusFilter != c.statusFilter ||
          p.currentSourceOnly != c.currentSourceOnly,
      builder: (context, state) => ListenableBuilder(
        listenable: sl<SearchSourcePrefs>(),
        builder: (context, _) {
          // Source excludes only count as an active filter when actually
          // fanning out to all sources.
          final sourceExcluded =
              !state.currentSourceOnly &&
              sl<SearchSourcePrefs>().excluded.isNotEmpty;
          final count = state.activeFilterCount + (sourceExcluded ? 1 : 0);
          return _iconWithBadge(
            icon: Icons.tune_rounded,
            tooltip: 'Filters',
            count: count,
            onPressed: () => _openFilterSheet(context),
          );
        },
      ),
    );
  }

  /// A control-row icon button with a small accent count badge in the corner
  /// when [count] > 0 — used by [_filterAction] to surface how many
  /// sort/type/audio/genre/source selections are non-default at a glance,
  /// instead of a bare on/off tint.
  Widget _iconWithBadge({
    required IconData icon,
    required String tooltip,
    required int count,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IconButton(
            icon: Icon(
              icon,
              size: 20,
              color: count > 0 ? AppColors.accent : AppColors.textTertiary,
            ),
            tooltip: tooltip,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          if (count > 0)
            Positioned(
              top: 3,
              right: 3,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  constraints: const BoxConstraints(minWidth: 14),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.surface, width: 1.5),
                  ),
                  child: Text(
                    '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Per-source filter routing for [sourceId] by [sourceFilterEcosystemOf] —
  /// the tap handler for the section-header tune icon (or null to hide it)
  /// plus whether a selection is already stored (drives the active tint).
  /// Shared by [_sourceFilterAction] and both source-section headers
  /// ([_sourceRow]/[_sourceGrid]) so the routing lives in exactly one place.
  ({VoidCallback? onFilter, bool active}) _sourceFilterFor(
    String sourceId,
    SearchState state,
  ) {
    return switch (sourceFilterEcosystemOf(sourceId)) {
      SourceFilterEcosystem.aniyomi => (
          onFilter: () => _openAniFilters(sourceId),
          active: state.aniFiltersBySource.containsKey(sourceId),
        ),
      SourceFilterEcosystem.mihon => (
          onFilter: () => _openMihonFilters(sourceId),
          active: state.mihonFiltersBySource.containsKey(sourceId),
        ),
      null => (onFilter: null, active: false),
    };
  }

  /// Per-source filter action (Aniyomi or Mihon). In single-source mode
  /// there's no per-source section header to host it (the old scope pill
  /// surfaced it beside itself for the same reason), so it lives here —
  /// shown only when scoped to a source with a per-source filter sheet; see
  /// [sourceFilterEcosystemOf].
  Widget _sourceFilterAction() {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) =>
          p.currentSourceOnly != c.currentSourceOnly ||
          p.aniFiltersBySource != c.aniFiltersBySource ||
          p.mihonFiltersBySource != c.mihonFiltersBySource,
      builder: (context, state) {
        if (!state.currentSourceOnly) return const SizedBox.shrink();
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) {
            final filter = _sourceFilterFor(activeId, state);
            if (filter.onFilter == null) return const SizedBox.shrink();
            return IconButton(
              onPressed: filter.onFilter,
              icon: Icon(
                Icons.tune_rounded,
                size: 20,
                color: filter.active
                    ? AppColors.accent
                    : AppColors.textTertiary,
              ),
              tooltip: 'Source filters',
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            );
          },
        );
      },
    );
  }

  // ── Ecosystem tabs (All · Zangetsu · CloudStream · Aniyomi) ────────────────
  /// Real [TabBar]/[TabController] pair — same treatment as the History
  /// screen's tabs (`history_screen.dart:321`): sliding rounded accent
  /// underline + label-colour crossfade instead of a static border, so
  /// switching tabs actually animates. [isScrollable] + [TabAlignment.start]
  /// keep it left-anchored regardless of how many tabs are present. "All"
  /// (first, default) applies no filter — selecting a tab is a pure view
  /// filter over already-fetched groups; see [SearchEcosystemChanged].
  Widget _ecosystemTabs(SearchState state, List<SearchEcosystem> tabs) {
    final controller = _ecoTabControllerFor(tabs, state.ecosystem);
    return TabBar(
      controller: controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      padding: EdgeInsets.zero,
      labelPadding: const EdgeInsets.only(right: 20),
      // Drop the default full-width hairline under the bar, same as History.
      dividerColor: Colors.transparent,
      dividerHeight: 0,
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderRadius: const BorderRadius.all(Radius.circular(2)),
        borderSide: BorderSide(width: 3, color: AppColors.accent),
        insets: const EdgeInsets.symmetric(horizontal: -6),
      ),
      labelColor: AppColors.accent,
      unselectedLabelColor: AppColors.textSecondary,
      // History uses 14.5 — sized down here since this row also hosts the
      // sort/filter icons and has less height to spend.
      labelStyle: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelStyle: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      overlayColor: WidgetStateProperty.all(Colors.transparent),
      onTap: (i) =>
          context.read<SearchBloc>().add(SearchEcosystemChanged(tabs[i])),
      tabs: [for (final t in tabs) Tab(text: t.label)],
    );
  }

  /// Keeps [_ecoTabController] glued to the CURRENT tab set/selection so it
  /// can never throw from a length mismatch: [ecosystemTabsFor] is recomputed
  /// every relevant build (tabs appear/disappear as sources are
  /// installed/removed while the screen is open), so the controller is
  /// recreated whenever the tab list itself changes, and just re-indexed in
  /// place when only the selection changes (e.g. [SearchState.ecosystem]
  /// getting reset to "All" by a fresh search or a scope change). Falls back
  /// to index 0 ("All") if the previously-selected ecosystem isn't in the new
  /// tab set.
  TabController _ecoTabControllerFor(
    List<SearchEcosystem> tabs,
    SearchEcosystem selected,
  ) {
    final target = tabs.indexOf(selected);
    final index = target < 0 ? 0 : target;
    if (_ecoTabController == null || !listEquals(_ecoTabs, tabs)) {
      _ecoTabController?.dispose();
      _ecoTabs = tabs;
      _ecoTabController = TabController(
        length: tabs.length,
        vsync: this,
        initialIndex: index,
      );
    } else if (_ecoTabController!.index != index) {
      _ecoTabController!.index = index;
    }
    return _ecoTabController!;
  }

  // ── Per-source result pills (jump straight to one source) ──────────────────
  /// Recovered from the pre-redesign source-chip row (`_filterChips`/`_chip`,
  /// deleted when the grouped grid went 4-up) via `git show
  /// HEAD:lib/features/home/search_screen.dart`. Same selection logic
  /// byte-for-byte: [SearchState.sourceFilter] is a pure view filter over
  /// already-fetched [SearchState.groups] via [SearchSourceFilterChanged] —
  /// it never re-runs the search. [SearchState.sourceChipGroups] already
  /// narrows to the active ecosystem tab, so this row can't disagree with the
  /// tabs above it: switching ecosystems resets the pill selection back to
  /// "All" the same way the bloc already resets it on a fresh search or scope
  /// change (see `SearchBloc._onEcosystemChanged`).
  Widget _sourcePillsRow() {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) =>
          p.groups != c.groups ||
          p.sourceFilter != c.sourceFilter ||
          p.currentSourceOnly != c.currentSourceOnly ||
          p.contentFilter != c.contentFilter ||
          p.audioFilter != c.audioFilter ||
          p.genreFilter != c.genreFilter ||
          p.statusFilter != c.statusFilter ||
          p.ecosystem != c.ecosystem ||
          p.suggestions != c.suggestions ||
          p.status != c.status,
      builder: (context, state) {
        final showingSuggestions =
            state.status != SearchStatus.success &&
            state.suggestions.isNotEmpty;
        // Keep the row while a source pill is selected, so a selection that
        // filters down to nothing doesn't also hide the pills needed to undo
        // it. Base "enough sources to filter" on the sources that RETURNED
        // results, not the content-filtered view.
        final hasSelection = state.sourceFilter != kAllSources;
        // Computed once here instead of once for the length check and again
        // inside _filterChips.
        final chipGroups = state.sourceChipGroups;
        if (state.currentSourceOnly ||
            showingSuggestions ||
            state.status != SearchStatus.success ||
            (chipGroups.length < 2 && !hasSelection)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: _filterChips(state, chipGroups),
        );
      },
    );
  }

  Widget _filterChips(SearchState state, List<SourceResultGroup> groups) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip(
            label: 'All ${state.totalCount}',
            selected: state.sourceFilter == kAllSources,
            onTap: () => context.read<SearchBloc>().add(
              const SearchSourceFilterChanged(kAllSources),
            ),
          ),
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _chip(
                label: '${g.sourceName} ${state.countFor(g)}',
                selected: state.sourceFilter == g.sourceId,
                onTap: () => context.read<SearchBloc>().add(
                  SearchSourceFilterChanged(g.sourceId),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Minimal pill styling to match the redesign: quiet surface fill + hairline
  /// border at rest, a subtle accent TINT (not a solid fill) when selected.
  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.14)
                : AppColors.surface,
            border: Border.all(color: AppColors.hairline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: AppText.caption.copyWith(
              fontSize: 12,
              color: selected ? AppColors.accent : AppColors.textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  // ── Results body (grouped per source, layout-aware) ─────────────────────────
  Widget _resultsBody(
    SearchState state,
    double cellW,
    List<({String id, String name})> modeSources,
  ) {
    final groups = state.sortedVisibleGroups;

    // Sources still loading: those switched on for search that haven't
    // RESPONDED yet (not just those without a visible group — a source that
    // came back empty or errored still counts as done, via respondedSources;
    // see SearchBloc._runSearch). Without that check a source with zero
    // results kept its skeleton on screen forever, since `landed` alone can
    // never distinguish "hasn't answered" from "answered with nothing". Only
    // when viewing all sources — a selected source chip means the user has
    // narrowed to one, so other sources' skeletons would be noise.
    final prefs = sl<SearchSourcePrefs>();
    final landed = {for (final g in state.groups) g.sourceId};
    // Current-source-only mode queries a single source, so there are never
    // other sources still streaming in — no skeleton sections. On a specific
    // ecosystem tab, only that ecosystem's still-loading sources get skeletons
    // (the "All" tab keeps every pending source, i.e. current behaviour).
    final pending =
        (state.currentSourceOnly || state.sourceFilter != kAllSources)
        ? const <({String id, String name})>[]
        : modeSources
              .where(
                (s) =>
                    prefs.isIncluded(s.id) &&
                    !landed.contains(s.id) &&
                    !state.respondedSources.contains(s.id) &&
                    (state.ecosystem == SearchEcosystem.all ||
                        ecosystemOf(s.id) == state.ecosystem),
              )
              .toList();
    final stillLoading = pending.isNotEmpty;

    if (groups.isEmpty && !stillLoading) {
      return _noResults(state);
    }

    // A single-source view reads best as the dense flat grid rather than one
    // lonely section: either an explicit chip selection, or only one source
    // returned and nothing else is still streaming in.
    final singleSource =
        state.sourceFilter != kAllSources ||
        (groups.length == 1 && !stillLoading);
    final layout = _searchPrefs.layout;

    // A single source always reads best as the full grid — a lone horizontal
    // row is cramped — regardless of the All-view layout setting. 3 columns
    // (grouped-by-source sections below are the denser 4-up grid).
    if (singleSource) {
      return _resultsGrid(state.visibleResults, cellW);
    }

    return ListView(
      padding: EdgeInsets.only(
        top: 6,
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
      ),
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

  /// Section header — source name (semibold) + a muted count next to it. When
  /// [onSeeAll] is provided a right-aligned muted "See all ›" link opens that
  /// source's full results (shown only when the section is capped).
  ///
  /// [onFilter] and [filterActive] are for Aniyomi (`ani:`) sources only.
  ///
  /// [pending] renders the "still searching" skeleton-header variant: the name
  /// muted and "searching…" where the count goes, instead of a real count.
  Widget _sectionHeader(
    String name,
    int count, {
    VoidCallback? onSeeAll,
    VoidCallback? onFilter,
    bool filterActive = false,
    bool pending = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    style: AppText.body.copyWith(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: pending
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (pending || count > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    pending ? 'searching…' : '$count',
                    style: AppText.caption.copyWith(fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
          if (onFilter != null)
            IconButton(
              onPressed: onFilter,
              icon: Icon(
                Icons.tune_rounded,
                size: 20,
                color: filterActive ? AppColors.accent : AppColors.textTertiary,
              ),
              tooltip: 'Source filters',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
                        color: AppColors.textTertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: AppColors.textTertiary,
                    ),
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
    final filter = _sourceFilterFor(
      g.sourceId,
      context.read<SearchBloc>().state,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionHeader(
          g.sourceName,
          g.items.length,
          onSeeAll: overflows ? () => _openSourceSeeAll(g) : null,
          onFilter: filter.onFilter,
          filterActive: filter.active,
        ),
        SizedBox(
          height: itemH,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // With a screen reader on, build every poster (not just the lazy
            // window) so TalkBack can reach each one and the row auto-scrolls to
            // it — otherwise swipe navigation stalls at the first few. Sighted
            // users keep the lazy 600px window unchanged.
            // `accessibleNavigationOf`, not `MediaQuery.of(...)`: the latter
            // subscribes to every aspect including viewInsets, so each row
            // rebuilt on every frame of the keyboard sliding in or out.
            cacheExtent: MediaQuery.accessibleNavigationOf(context)
                ? double.infinity
                : 600,
            itemCount: preview.length,
            itemBuilder: (context, i) {
              final item = preview[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: itemW,
                  child: RepaintBoundary(
                    child: RevealItem(
                      index: i,
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
    final filter = _sourceFilterFor(
      g.sourceId,
      context.read<SearchBloc>().state,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionHeader(
          g.sourceName,
          g.items.length,
          onSeeAll: overflows ? () => _openSourceSeeAll(g) : null,
          onFilter: filter.onFilter,
          filterActive: filter.active,
        ),
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
            return RevealItem(
              index: i,
              child: PosterCard(
                title: item.title,
                imageUrl: item.cover,
                headers: item.coverHeaders,
                tags: _tagsFor(item),
                cellWidth: cellW,
                onTap: () => _openDetail(item),
                onLongPress: () => _showInfo(item),
              ),
            );
          },
        ),
      ],
    );
  }

  /// A loading skeleton for a source section that hasn't returned yet — name
  /// muted, "searching…" where the count goes, grid matching [_sourceGrid].
  Widget _skeletonSection(String name, SearchLayout layout) {
    if (layout == SearchLayout.horizontal) {
      return const RowSkeleton();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionHeader(name, 0, pending: true),
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
            const Icon(
              Icons.search_off_rounded,
              size: 52,
              color: AppColors.textTertiary,
            ),
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
                    ..add(
                      const SearchContentFilterChanged(SearchContentFilter.all),
                    )
                    ..add(const SearchAudioFilterChanged(SearchAudioFilter.any))
                    ..add(const SearchGenreFilterChanged(null));
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
      padding: EdgeInsets.fromLTRB(
        16,
        6,
        16,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
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
    // Recent searches are hidden during a filtered browse — the screen is
    // showing filter results, not a search landing page, and the chips would
    // push them below the fold.
    final recent = state.hasFilteredBrowse
        ? const <String>[]
        : _history.recent();
    // A filters-only browse (source filters set with an empty search box)
    // replaces "Top picks" — those results ARE what the filters asked for.
    // Falls back to trending the moment the filters are cleared.
    final browsing = state.hasFilteredBrowse;
    final trending = browsing ? state.filteredBrowse : state.trending;

    if (recent.isEmpty && trending.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded, size: 48, color: AppColors.textTertiary),
            SizedBox(height: 12),
            Text(
              'Search for something to watch',
              textAlign: TextAlign.center,
              style: AppText.body,
            ),
          ],
        ),
      );
    }

    final cellW = (MediaQuery.sizeOf(context).width - 40 - 24) / 3;
    return NotificationListener<ScrollNotification>(
      // Infinite scroll for a filtered browse, the way Aniyomi keeps paging one.
      // The bloc ignores the event unless a browse is active and idle, so this
      // costs nothing on the normal idle screen.
      onNotification: (n) {
        if (browsing &&
            state.canLoadMoreFilteredBrowse &&
            n.metrics.axis == Axis.vertical &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 600) {
          context.read<SearchBloc>().add(const SearchFilteredBrowseMore());
        }
        return false;
      },
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
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
            if (browsing)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Filtered · ${_repo.displayName(state.filteredBrowseSourceId)}',
                      style: AppText.overline,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.read<SearchBloc>().add(
                      SearchSourceFiltersApplied(
                        state.filteredBrowseSourceId,
                        '',
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        'Clear',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else
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
            if (browsing && state.filteredBrowseLoadingMore)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ── Type-ahead suggestion list (history + live titles) ────────────────────
  Widget _suggestionList(List<String> suggestions) {
    final history = _history.recent().map((e) => e.toLowerCase()).toSet();
    return ListView.builder(
      padding: EdgeInsets.only(
        top: 4,
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
      ),
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
                child: Icon(
                  Icons.north_west_rounded,
                  size: 16,
                  color: AppColors.textTertiary,
                ),
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
            const Icon(
              Icons.history_rounded,
              size: 15,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              q,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () async {
                await _history.remove(q);
                if (mounted) setState(() {});
              },
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The filter sheet's "search in these sources" category list. Anime mode's
/// three categories (in this exact order) are the original hardcoded
/// literal, untouched; a reading mode gets its own single category (Manga or
/// Novel) instead of Anime/Movies & Series/NSFW, which are always empty for
/// it anyway. Mirrors `_SourcePickerSheetState._grouped()`'s categories in
/// source_switcher.dart. A top-level function (not inlined in
/// [_SearchFilterSheet]) so it's unit-testable without a real [SearchBloc].
List<({String title, List<({String id, String label, String? repo})> rows})>
searchFilterSections(SourceBuckets buckets, ContentMode mode) {
  final readingBucket = mode == ContentMode.manga
      ? buckets.manga
      : buckets.novel;
  return [
    if (!mode.isReading && buckets.anime.isNotEmpty)
      (title: 'Anime', rows: buckets.anime),
    if (!mode.isReading && buckets.movies.isNotEmpty)
      (title: 'Movies & Series', rows: buckets.movies),
    if (!mode.isReading && buckets.nsfw.isNotEmpty)
      (title: 'NSFW', rows: buckets.nsfw),
    if (mode.isReading && readingBucket.isNotEmpty)
      (title: mode.label, rows: readingBucket),
  ];
}

/// Whether the filter sheet's Type and Audio groups apply in [mode]. Both are
/// anime-only concepts — [SearchContentFilter] only distinguishes anime vs
/// movie (nothing manga/novel results ever are), and [SearchAudioFilter] keys
/// off [MediaItem.subCount]/[dubCount], which reading sources never set.
/// Showing either group outside anime mode used to let every option filter
/// out 100% of results. A top-level function (same pattern as
/// [searchFilterSections]) so it's unit-testable without pumping the sheet.
bool searchTypeAudioGroupsVisible(ContentMode mode) => !mode.isReading;

/// Which ecosystem's per-source filter sheet [sourceId] opens — Aniyomi for
/// `ani:` ids, Mihon for `mihon:` ids, or null for everything else (no
/// per-source filter button shown). Drives the filter icon on the
/// single-source control row ([_SearchViewState._sourceFilterAction]) and both
/// source-section headers. A top-level function (same pattern as
/// [searchFilterSections]) so it's unit-testable without pumping the sheet.
enum SourceFilterEcosystem { aniyomi, mihon }

SourceFilterEcosystem? sourceFilterEcosystemOf(String sourceId) {
  if (sourceId.startsWith('ani:')) return SourceFilterEcosystem.aniyomi;
  if (sourceId.startsWith('mihon:')) return SourceFilterEcosystem.mihon;
  return null;
}

/// The filter sheet's "no sources" state. Anime mode's wording (a bare,
/// button-less line) is unchanged; a reading mode gets a reading-specific
/// message and an install CTA — same wording/route as the source picker's
/// install CTA and Home's [HomeLoadedEmptyView].
class SearchSourcesEmptyView extends StatelessWidget {
  const SearchSourcesEmptyView({
    super.key,
    required this.mode,
    required this.onInstallSources,
  });

  final ContentMode mode;
  final VoidCallback onInstallSources;

  @override
  Widget build(BuildContext context) {
    if (!mode.isReading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: Text('No sources installed', style: AppText.body)),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: EmptyState(
        icon: Icons.source_outlined,
        message: 'No ${mode.label} sources yet',
        actionLabel: 'Browse repositories',
        onAction: onInstallSources,
      ),
    );
  }
}

/// The merged filter sheet: Sort · Type (anime only) · Audio (anime only) ·
/// Genre, plus a single "Search in sources" row that opens the categorised
/// source list as its own sub-sheet ([_openSourcesSheet]). Every group here
/// filters/sorts real data — see [SearchState] — and every selection applies
/// live via the bloc, so the footer's primary button always reads the
/// CURRENT result count rather than something computed after closing.
class _SearchFilterSheet extends StatelessWidget {
  const _SearchFilterSheet();

  /// Resets every group in this sheet back to its default, including
  /// [SearchSort] — sort now lives in the same sheet as the narrowing
  /// filters, so one Reset covers both.
  void _reset(BuildContext context, List<String> allIds) {
    final state = context.read<SearchBloc>().state;
    if (!state.currentSourceOnly) {
      sl<SearchSourcePrefs>().setManyIncluded(allIds, true);
    }
    context.read<SearchBloc>()
      ..add(const SearchSortChanged(SearchSort.bestMatch))
      ..add(const SearchContentFilterChanged(SearchContentFilter.all))
      ..add(const SearchAudioFilterChanged(SearchAudioFilter.any))
      ..add(const SearchGenreFilterChanged(null))
      ..add(const SearchStatusFilterChanged(SearchStatusFilter.any));
  }

  bool _canReset(SearchState state, SearchSourcePrefs prefs) =>
      state.hasActiveFilter ||
      state.sort != SearchSort.bestMatch ||
      (!state.currentSourceOnly && prefs.excluded.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    // bloc/widget tests don't always register ContentModeCubit — fall back to
    // anime, which shows every group (the pre-mode-awareness behaviour).
    final mode = sl.isRegistered<ContentModeCubit>()
        ? sl<ContentModeCubit>().state
        : ContentMode.anime;
    final buckets = filterBucketsForMode(categorizedSources(), mode);
    final prefs = sl<SearchSourcePrefs>();
    final sections = searchFilterSections(buckets, mode);
    final allIds = [for (final s in sections) ...s.rows.map((r) => r.id)];
    final showTypeAudio = searchTypeAudioGroupsVisible(mode);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
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
            _header(context, allIds, prefs),
            Flexible(
              child: ListenableBuilder(
                listenable: prefs,
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    _sortSelector(context),
                    if (showTypeAudio) _contentTypeSelector(context),
                    // Audio needs BOTH anime mode and results that actually
                    // report sub/dub counts — movie sources never set them, so
                    // without the second test the group shows and either choice
                    // empties the list. Same rule Genre and Status already use.
                    if (showTypeAudio &&
                        context.watch<SearchBloc>().state.hasAnyAudio)
                      _audioSelector(context),
                    _genreSelector(context),
                    _statusSelector(context),
                    if (!context.read<SearchBloc>().state.currentSourceOnly)
                      _sourcesSummaryRow(context, sections, prefs, mode),
                  ],
                ),
              ),
            ),
            _footer(context, allIds, prefs),
          ],
        ),
      ),
    );
  }

  /// "Filters" + a live count badge + Reset (hidden while there's nothing to
  /// reset).
  Widget _header(
    BuildContext context,
    List<String> allIds,
    SearchSourcePrefs prefs,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(
        children: [
          Text('Filters', style: AppText.headline),
          const SizedBox(width: 8),
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (p, c) =>
                p.sort != c.sort ||
                p.contentFilter != c.contentFilter ||
                p.audioFilter != c.audioFilter ||
                p.genreFilter != c.genreFilter ||
                p.statusFilter != c.statusFilter,
            builder: (context, state) {
              final count = state.activeFilterCount;
              if (count == 0) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              );
            },
          ),
          const Spacer(),
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (p, c) =>
                p.contentFilter != c.contentFilter ||
                p.audioFilter != c.audioFilter ||
                p.genreFilter != c.genreFilter ||
                p.statusFilter != c.statusFilter ||
                p.sort != c.sort ||
                p.currentSourceOnly != c.currentSourceOnly,
            builder: (context, state) {
              if (!_canReset(state, prefs)) return const SizedBox.shrink();
              return TextButton(
                onPressed: () => _reset(context, allIds),
                child: Text(
                  'Reset',
                  style: AppText.body.copyWith(color: AppColors.accent),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Reset (ghost, hidden while there's nothing to reset) + the primary
  /// action, which states the outcome ("Show N results") rather than just
  /// "Done" — N is [SearchState.totalCount], the SAME live, already-fetched
  /// count the "N results"/pill labels use elsewhere on this screen, so it
  /// updates the instant a pill is tapped without any re-search.
  Widget _footer(
    BuildContext context,
    List<String> allIds,
    SearchSourcePrefs prefs,
  ) {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) =>
          p.contentFilter != c.contentFilter ||
          p.audioFilter != c.audioFilter ||
          p.genreFilter != c.genreFilter ||
          p.statusFilter != c.statusFilter ||
          p.sort != c.sort ||
          p.groups != c.groups ||
          p.ecosystem != c.ecosystem ||
          p.currentSourceOnly != c.currentSourceOnly,
      builder: (context, state) {
        final canReset = _canReset(state, prefs);
        final n = state.totalCount;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: Row(
              children: [
                if (canReset) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _reset(context, allIds),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.hairline),
                        foregroundColor: AppColors.textSecondary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Reset'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text('Show $n result${n == 1 ? '' : 's'}'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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

  /// A selectable pill (chip) used across the filter selectors. Unselected:
  /// quiet surface fill. Selected: a soft accent TINT (not a solid fill) with
  /// a matching subtle accent border, so the active pill reads as "on" without
  /// shouting.
  Widget _pill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: AppText.caption.copyWith(
            color: selected ? AppColors.accent : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// Sort selector, merged in from the old standalone sort sheet. Applies
  /// immediately, same as every other pill here.
  Widget _sortSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('SORT'),
          const SizedBox(height: 10),
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (p, c) => p.sort != c.sort,
            builder: (context, state) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in SearchSort.values)
                  _pill(
                    label: s.label,
                    selected: state.sort == s,
                    onTap: () =>
                        context.read<SearchBloc>().add(SearchSortChanged(s)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// The content-type segmented selector, wired to the bloc so the results
  /// filter updates the moment a chip is tapped. Anime mode only — see
  /// [searchTypeAudioGroupsVisible].
  Widget _contentTypeSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('TYPE'),
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
                    onTap: () => context.read<SearchBloc>().add(
                      SearchContentFilterChanged(f),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// Audio (Subbed/Dubbed) selector — real data, see
  /// [MediaItem.subCount]/[dubCount]. Anime mode only.
  Widget _audioSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLabel('AUDIO'),
          const SizedBox(height: 10),
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (p, c) => p.audioFilter != c.audioFilter,
            builder: (context, state) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in SearchAudioFilter.values)
                  _pill(
                    label: f.label,
                    selected: state.audioFilter == f,
                    onTap: () => context.read<SearchBloc>().add(
                      SearchAudioFilterChanged(f),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// Genre selector, pills derived from the actual result set
  /// ([SearchState.availableGenres]) rather than a fixed list — a genre only
  /// appears here if some result can actually match it. "Any" clears it.
  /// Hidden entirely when there's nothing to offer AND no filter is active;
  /// kept visible (with just "Any") while a filter is active so a stale
  /// selection is always reachable to clear.
  Widget _genreSelector(BuildContext context) {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) =>
          p.genreFilter != c.genreFilter || p.groups != c.groups,
      builder: (context, state) {
        final available = state.availableGenres;
        if (available.isEmpty && state.genreFilter == null) {
          return const SizedBox.shrink();
        }
        final selectedLower = state.genreFilter?.trim().toLowerCase();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _filterLabel('GENRE'),
                  const SizedBox(width: 6),
                  Text(
                    '· from your results',
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _pill(
                    label: 'Any',
                    selected: state.genreFilter == null,
                    onTap: () => context.read<SearchBloc>().add(
                      const SearchGenreFilterChanged(null),
                    ),
                  ),
                  for (final g in available)
                    _pill(
                      label: g,
                      selected: g.toLowerCase() == selectedLower,
                      onTap: () {
                        final next = g.toLowerCase() == selectedLower
                            ? null
                            : g;
                        context.read<SearchBloc>().add(
                          SearchGenreFilterChanged(next),
                        );
                      },
                    ),
                ],
              ),
              if (state.genreFilter != null && state.hasItemsWithoutGenre) ...[
                const SizedBox(height: 6),
                Text(
                  "some sources don't provide genres",
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  /// Status (Ongoing/Completed) selector — real data, see [MediaItem.status]
  /// (carried from Mihon/Aniyomi, same as [MediaDetail.status]). Not mode-
  /// gated like Type/Audio — both manga (Mihon) and anime (Aniyomi) sources
  /// report it — instead it self-hides via [SearchState.hasAnyStatus], same
  /// spirit as the genre selector self-hiding when there's nothing to offer;
  /// kept visible while a filter is active so a stale selection stays
  /// reachable to clear.
  Widget _statusSelector(BuildContext context) {
    return BlocBuilder<SearchBloc, SearchState>(
      buildWhen: (p, c) =>
          p.statusFilter != c.statusFilter || p.groups != c.groups,
      builder: (context, state) {
        if (!state.hasAnyStatus &&
            state.statusFilter == SearchStatusFilter.any) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _filterLabel('STATUS'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in SearchStatusFilter.values)
                    _pill(
                      label: f.label,
                      selected: state.statusFilter == f,
                      onTap: () => context.read<SearchBloc>().add(
                        SearchStatusFilterChanged(f),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  /// A single tappable row summarising the "search in these sources" list —
  /// "Search in sources · N of M ›" — that opens the exact same categorised
  /// switches as a sub-sheet ([_openSourcesSheet]), so the main sheet stays
  /// short instead of listing every source inline.
  Widget _sourcesSummaryRow(
    BuildContext context,
    List<({String title, List<({String id, String label, String? repo})> rows})>
    sections,
    SearchSourcePrefs prefs,
    ContentMode mode,
  ) {
    final allIds = [for (final s in sections) ...s.rows.map((r) => r.id)];
    final onCount = allIds.where(prefs.isIncluded).length;
    return InkWell(
      onTap: () => _openSourcesSheet(context, sections, prefs, mode),
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.hairline)),
        ),
        child: Row(
          children: [
            Text(
              'Search in sources',
              style: AppText.body.copyWith(
                fontSize: 13.5,
                color: AppColors.textPrimary,
              ),
            ),
            const Spacer(),
            Text(
              '$onCount of ${allIds.length}',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  /// The "search in these sources" sub-sheet — same categorised
  /// switches/"turn all on/off" behaviour as before, just moved off the main
  /// sheet. [filterSheetContext] is the MAIN sheet's context, kept so the
  /// empty-state's install CTA can close both sheets and push
  /// [ZangetsuSourcesScreen], same as it always has.
  void _openSourcesSheet(
    BuildContext filterSheetContext,
    List<({String title, List<({String id, String label, String? repo})> rows})>
    sections,
    SearchSourcePrefs prefs,
    ContentMode mode,
  ) {
    showModalBottomSheet<void>(
      context: filterSheetContext,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (subCtx) => ListenableBuilder(
        listenable: prefs,
        builder: (subCtx, _) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(subCtx).size.height * 0.8,
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
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Search in sources', style: AppText.headline),
                  ),
                ),
                Flexible(
                  child: sections.isEmpty
                      ? SearchSourcesEmptyView(
                          mode: mode,
                          onInstallSources: () {
                            Navigator.of(subCtx).pop();
                            Navigator.of(filterSheetContext).pop();
                            Navigator.of(filterSheetContext).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ZangetsuSourcesScreen(
                                  openToRepos: true,
                                ),
                              ),
                            );
                          },
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 8),
                          children: [
                            for (final sec in sections) ...[
                              _categoryHeader(prefs, sec.title, sec.rows),
                              for (final r in sec.rows) _sourceRow(prefs, r),
                            ],
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(subCtx),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Done'),
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

  Widget _sourceRow(
    SearchSourcePrefs prefs,
    ({String id, String label, String? repo}) r,
  ) {
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
