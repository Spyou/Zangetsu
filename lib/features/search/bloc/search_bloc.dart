import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injector.dart';
import '../../../core/mode/content_mode.dart';
import '../../../core/mode/content_mode_cubit.dart';
import '../../../core/models/media_item.dart';
import '../../../core/playback/search_history.dart';
import '../../../core/playback/search_prefs.dart';
import '../../../core/playback/search_source_prefs.dart';
import '../../../core/playback/source_health_store.dart';
import '../../../core/repository/source_repository.dart';
import '../../../core/search/title_suggestion_service.dart';
import '../../../core/state/active_source_cubit.dart';
// sourceTypeOf lives with the source picker; search_screen.dart reaches for it
// the same way for its own mode narrowing.
import '../../../core/ui/source_switcher.dart';
import 'search_event.dart';
import 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc({
    required SourceRepository repo,
    required SearchHistory history,
    SearchPrefs? prefs,
    TitleSuggestionService? suggestions,
  }) : _repo = repo,
       _history = history,
       _prefs = prefs ?? sl<SearchPrefs>(),
       _suggestions = suggestions ?? sl<TitleSuggestionService>(),
       super(_restoredState(prefs ?? sl<SearchPrefs>())) {
    on<SearchStarted>(_onStarted);
    on<SearchQueryChanged>(_onQueryChanged);
    on<SearchSuggestionsUpdated>(_onSuggestionsUpdated);
    on<SearchSortChanged>(_onSortChanged);
    on<SearchScopeChanged>(_onScopeChanged);
    on<SearchSourceFilterChanged>(_onSourceFilterChanged);
    on<SearchEcosystemChanged>(_onEcosystemChanged);
    on<SearchContentFilterChanged>(_onContentFilterChanged);
    on<SearchAudioFilterChanged>(_onAudioFilterChanged);
    on<SearchGenreFilterChanged>(_onGenreFilterChanged);
    on<SearchStatusFilterChanged>(_onStatusFilterChanged);
    on<SearchRunRequested>(_onRunRequested);
    on<SearchSubmitted>(_onSubmitted);
    on<SearchSourceFiltersApplied>(_onSourceFiltersApplied);
    on<SearchFilteredBrowseMore>(_onFilteredBrowseMore);
    on<SearchModeChanged>(_onModeChanged);
    // Results belong to the mode they were fetched in. The Search tab stays
    // alive in the nav shell, so without this a manga search was still on
    // screen after switching to Streaming — stale results from sources this
    // mode doesn't even search. Listening here rather than in the screen means
    // it also holds when the mode is changed from Home and Search is opened
    // afterwards.
    // Guarded: bloc tests construct SearchBloc with explicit deps and never
    // register the cubit, and subscribing unconditionally would blow up at
    // construction before such a test does anything. Production always has it.
    if (sl.isRegistered<ContentModeCubit>()) {
      _modeSub = sl<ContentModeCubit>().stream.listen((_) {
        add(const SearchModeChanged());
      });
    }
  }

  final SourceRepository _repo;
  final SearchHistory _history;
  final SearchPrefs _prefs;
  final TitleSuggestionService _suggestions;
  StreamSubscription<ContentMode>? _modeSub;

  /// [SourceRepository.loadedSources] narrowed to the active content mode, so an
  /// all-sources search only fans out over sources that mode can actually show —
  /// a manga search shouldn't query novel (or anime) sources, and vice versa.
  ///
  /// Mirrors `_modeSources` in `search_screen.dart`, which already narrows the
  /// source *list* the UI offers; without the same narrowing here the bloc
  /// searched everything regardless of mode, so the picker and the results
  /// disagreed.
  ///
  /// Every mode narrows, anime included. Anime used to short-circuit to the
  /// unfiltered list — harmless when the only sources were video ones, but once
  /// Mihon (`mihon:`) and LNReader (`lnr:`) became installable it meant an
  /// anime search quietly queried every manga and novel source too, and their
  /// results rendered as ordinary groups. Nothing is lost by filtering here:
  /// `ContentMode.anime.matchesProvider` accepts anime AND movie, and
  /// `sourceTypeOf` types `cs:`/`ani:`/untyped sources as anime, so the only
  /// sources this drops are the manga and novel ones.
  List<({String id, String name})> _modeSources() {
    final mode = sl<ContentModeCubit>().state;
    return filterSourcesForMode(
      {for (final s in _repo.loadedSources) s.id: s},
      mode,
      (s) => sourceTypeOf(s.id),
    ).values.toList();
  }

  /// Seeds the bloc with the user's remembered filter/sort choices so they
  /// persist across screen opens.
  static SearchState _restoredState(SearchPrefs prefs) {
    final content = SearchContentFilter.values.firstWhere(
      (f) => f.name == prefs.contentFilterName,
      orElse: () => SearchContentFilter.all,
    );
    final sort = SearchSort.values.firstWhere(
      (s) => s.name == prefs.sortName,
      orElse: () => SearchSort.bestMatch,
    );
    // Same fallback pattern migrates an old 'rating' sort name (the enum
    // value no longer exists) straight to bestMatch — nothing else needed.
    final audio = SearchAudioFilter.values.firstWhere(
      (f) => f.name == prefs.audioFilterName,
      orElse: () => SearchAudioFilter.any,
    );
    final statusFilter = SearchStatusFilter.values.firstWhere(
      (f) => f.name == prefs.statusFilterName,
      orElse: () => SearchStatusFilter.any,
    );
    return SearchState(
      contentFilter: content,
      sort: sort,
      audioFilter: audio,
      genreFilter: prefs.genre,
      statusFilter: statusFilter,
      currentSourceOnly: prefs.currentSourceOnly,
    );
  }

  /// Debounce for the LIGHTWEIGHT autocomplete only — never the heavy search.
  Timer? _suggestDebounce;

  /// Bumped per autocomplete fetch so a slow response can't overwrite a newer
  /// query's suggestions.
  int _suggestSeq = 0;

  /// The last query an actual search was run for. When the field text drifts
  /// away from this, we drop back to the suggestion view so typing after a
  /// completed search shows fresh suggestions instead of stale results.
  String _lastRunQuery = '';
  // Bumped on every _runSearch. A run only emits while it's still the latest —
  // so toggling scope (or any re-run) with the SAME query can't let the previous
  // run keep streaming its (e.g. all-sources) results over the new one.
  int _runGen = 0;

  Future<void> _onStarted(
    SearchStarted event,
    Emitter<SearchState> emit,
  ) async {
    if (state.trending.isNotEmpty) return;
    try {
      final sections = await _repo.home();
      final items = sections.isNotEmpty
          ? sections.first.items.take(12).toList()
          : <MediaItem>[];
      emit(state.copyWith(trending: items));
    } catch (_) {
      /* trending is best-effort */
    }
  }

  /// Typing ONLY updates the field text and (debounced) fetches lightweight
  /// suggestions. It NEVER starts the multi-source provider search — that runs
  /// only on an explicit [SearchRunRequested] (Enter / icon / suggestion tap).
  void _onQueryChanged(SearchQueryChanged event, Emitter<SearchState> emit) {
    final q = event.query;
    emit(state.copyWith(query: q));
    _suggestDebounce?.cancel();

    final trimmed = q.trim();
    if (trimmed.isEmpty) {
      // Clearing the field returns to the idle screen and drops suggestions.
      emit(
        state.copyWith(
          groups: const [],
          suggestions: const [],
          status: SearchStatus.idle,
          clearError: true,
        ),
      );
      return;
    }

    // History matches are instant; show them immediately. If the field has
    // drifted away from the last-searched query, leave the results view (back
    // to idle) so the suggestion list takes over while typing the next query.
    final historyMatches = _historyMatches(trimmed);
    final driftedFromResults =
        state.status == SearchStatus.success &&
        trimmed.toLowerCase() != _lastRunQuery.toLowerCase();
    emit(
      state.copyWith(
        suggestions: historyMatches,
        status: driftedFromResults ? SearchStatus.idle : null,
        groups: driftedFromResults ? const [] : null,
      ),
    );

    // Then fetch live title autocomplete (one fast call) and merge it in.
    final seq = ++_suggestSeq;
    _suggestDebounce = Timer(const Duration(milliseconds: 250), () async {
      final live = await _suggestions.suggest(trimmed);
      if (isClosed || seq != _suggestSeq) return;
      add(SearchSuggestionsUpdated(_merge(historyMatches, live)));
    });
  }

  void _onSuggestionsUpdated(
    SearchSuggestionsUpdated event,
    Emitter<SearchState> emit,
  ) {
    // Drop suggestions once results are on screen (or the field was cleared).
    if (state.query.trim().isEmpty) return;
    emit(state.copyWith(suggestions: event.suggestions));
  }

  void _onSortChanged(SearchSortChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(sort: event.sort));
    _prefs.setSortName(event.sort.name);
  }

  /// Flips the search scope (current-source-only vs all sources), persists it,
  /// and re-runs the current query so the new scope takes effect immediately.
  Future<void> _onScopeChanged(
    SearchScopeChanged event,
    Emitter<SearchState> emit,
  ) async {
    if (event.currentSourceOnly == state.currentSourceOnly) return;
    // Reset the per-source chip — it's meaningless in current-source mode and
    // stale when switching back to all-sources.
    emit(
      state.copyWith(
        currentSourceOnly: event.currentSourceOnly,
        sourceFilter: kAllSources,
        ecosystem: SearchEcosystem.all,
      ),
    );
    _prefs.setCurrentSourceOnly(event.currentSourceOnly);
    if (state.query.trim().isNotEmpty) {
      await _runSearch(state.query.trim(), emit);
    }
  }

  void _onSourceFilterChanged(
    SearchSourceFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    emit(state.copyWith(sourceFilter: event.sourceId));
  }

  /// Switches the ecosystem tab. This is a pure VIEW filter over the loaded
  /// groups (no re-search). Switching tabs can hide the source group the
  /// per-source chip pointed at, so reset that chip to "all sources" — the user
  /// never lands on an empty filtered view.
  void _onEcosystemChanged(
    SearchEcosystemChanged event,
    Emitter<SearchState> emit,
  ) {
    emit(state.copyWith(ecosystem: event.ecosystem, sourceFilter: kAllSources));
  }

  void _onContentFilterChanged(
    SearchContentFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    // Switching content type can hide the active source group; fall back to
    // "All sources" so the user never lands on an empty filtered view.
    emit(
      state.copyWith(contentFilter: event.filter, sourceFilter: kAllSources),
    );
    _prefs.setContentFilterName(event.filter.name);
  }

  void _onAudioFilterChanged(
    SearchAudioFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    // Switching audio can hide the active source group; fall back to "All
    // sources" so the user never lands on an empty filtered view.
    emit(state.copyWith(audioFilter: event.filter, sourceFilter: kAllSources));
    _prefs.setAudioFilterName(event.filter.name);
  }

  void _onGenreFilterChanged(
    SearchGenreFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    emit(
      state.copyWith(
        genreFilter: event.genre,
        clearGenreFilter: event.genre == null,
        sourceFilter: kAllSources,
      ),
    );
    _prefs.setGenre(event.genre);
  }

  void _onStatusFilterChanged(
    SearchStatusFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    // Switching status can hide the active source group; fall back to "All
    // sources" so the user never lands on an empty filtered view.
    emit(state.copyWith(statusFilter: event.filter, sourceFilter: kAllSources));
    _prefs.setStatusFilterName(event.filter.name);
  }

  /// The single entry point for the heavy search. Sets [query] when provided
  /// (suggestion taps), cancels any pending autocomplete, clears suggestions,
  /// and runs the cross-source search.
  Future<void> _onRunRequested(
    SearchRunRequested event,
    Emitter<SearchState> emit,
  ) async {
    _suggestDebounce?.cancel();
    final q = (event.query ?? state.query).trim();
    if (q.isEmpty) return;
    // Reset only the per-search source chip + ecosystem tab — the user's
    // remembered sort and content/audio/genre filters persist across searches
    // (and screen opens); a fresh search always lands on the "All" tab.
    emit(
      state.copyWith(
        query: q,
        suggestions: const [],
        sourceFilter: kAllSources,
        ecosystem: SearchEcosystem.all,
      ),
    );
    await _runSearch(q, emit);
  }

  /// Re-runs the CURRENT query without resetting filters/sort — used by the
  /// filter sheet's Apply and the source picker.
  Future<void> _onSubmitted(
    SearchSubmitted event,
    Emitter<SearchState> emit,
  ) async {
    _suggestDebounce?.cancel();
    final q = state.query.trim();
    if (q.isEmpty) return;
    emit(state.copyWith(suggestions: const []));
    await _runSearch(q, emit);
  }

  /// Searches every selected source concurrently and emits each source's
  /// results as soon as they arrive (fast sources show first; one slow/broken
  /// source never blocks the rest).
  Future<void> _runSearch(String q, Emitter<SearchState> emit) async {
    final gen = ++_runGen; // this run is superseded once a newer one starts
    _lastRunQuery = q;
    _history.add(q);

    emit(
      state.copyWith(
        status: SearchStatus.loading,
        groups: const [],
        respondedSources: const {},
        clearError: true,
      ),
    );

    // Choose the sources to query. In current-source-only mode that's JUST the
    // active Home source (read live, so a later source switch is picked up). In
    // all-sources mode it's every loaded source EXCEPT the ones the user
    // switched off for search (search-only — doesn't affect Home use).
    List<({String id, String name})> sources;
    if (state.currentSourceOnly) {
      final activeId = sl<ActiveSourceCubit>().state;
      sources = [(id: activeId, name: _repo.displayName(activeId))];
    } else {
      final prefs = sl<SearchSourcePrefs>();
      sources = _modeSources().where((s) => prefs.isIncluded(s.id)).toList();
    }
    if (sources.isEmpty) {
      emit(state.copyWith(status: SearchStatus.error));
      return;
    }

    // Health-aware ordering + skipping (best-effort; never breaks search). In
    // all-sources mode: drop sources with a FRESH "dead" mark (they're retried
    // after the re-check window, never permanently blacklisted) and order the
    // rest healthiest-first so good sources stream their results soonest. In
    // current-source-only mode we always query the one chosen source (never skip
    // it — the user explicitly picked it).
    final health = sl<SourceHealthStore>();
    if (!state.currentSourceOnly) {
      final live = sources.where((s) => !health.isSkippable(s.id)).toList();
      // If EVERY source is currently skippable, the windows have likely all
      // lapsed-or-not together; rather than show nothing, retry them all.
      if (live.isNotEmpty) sources = live;
      int rank(SourceHealth h) => switch (h) {
        SourceHealth.ok => 0,
        SourceHealth.slow => 1,
        SourceHealth.dead => 2,
      };
      sources.sort(
        (a, b) =>
            rank(health.statusOf(a.id)).compareTo(rank(health.statusOf(b.id))),
      );
    }

    // Wipe the search cache if the loaded-source set changed since last time, so
    // a newly added/removed source is reflected immediately (per-source keying
    // already keeps a new source out of the cache; this covers removes too).
    _repo.syncSearchCache();

    final acc = <SourceResultGroup>[];
    var anyError = false;
    // Monotonic arrival counter: the Nth source to return non-empty results gets
    // arrivalIndex N, so sections render fastest-first (CloudStream-style).
    var arrived = 0;

    await Future.wait(
      sources.map((s) async {
        final sw = Stopwatch()..start();
        try {
          final res = await _repo.searchStatus(
            q,
            sourceId: s.id,
            filtersJson: state.aniFiltersBySource[s.id],
            cache: true,
          );
          sw.stop();
          if (isClosed || gen != _runGen) return; // superseded/closed
          // Record health: a response over the slow threshold downgrades an
          // otherwise-ok outcome to "slow"; error/timeout/blocked mark it dead
          // (recoverably); empty-without-error stays ok (NOT a strike).
          var outcome = res.outcome;
          final responded =
              outcome == SourceOutcome.ok || outcome == SourceOutcome.empty;
          if (responded && sw.elapsed > SourceHealthStore.slowThreshold) {
            outcome = SourceOutcome.slow;
          }
          // ignore: unawaited_futures
          health.record(s.id, outcome, responseMs: sw.elapsedMilliseconds);
          if (!responded && outcome != SourceOutcome.slow) anyError = true;
          if (res.items.isNotEmpty) {
            acc.add(
              SourceResultGroup(
                sourceId: s.id,
                sourceName: s.name,
                items: res.items,
                arrivalIndex: arrived++,
              ),
            );
            emit(
              state.copyWith(
                status: SearchStatus.success,
                groups: List.of(acc),
                respondedSources: {...state.respondedSources, s.id},
              ),
            );
          } else {
            // No results, but the source DID answer — mark it responded (without
            // touching status/groups) so its pending skeleton clears instead of
            // sitting there forever. See [SearchState.respondedSources].
            emit(
              state.copyWith(
                respondedSources: {...state.respondedSources, s.id},
              ),
            );
          }
        } catch (_) {
          // searchStatus is no-throw, but stay defensive — never let one source
          // break the fan-out. Still mark it responded so its skeleton clears.
          anyError = true;
          if (!isClosed && gen == _runGen) {
            emit(
              state.copyWith(
                respondedSources: {...state.respondedSources, s.id},
              ),
            );
          }
        }
      }),
    );

    if (isClosed || gen != _runGen) return;
    // Finalize: if nothing came back, surface error-or-empty appropriately.
    if (acc.isEmpty) {
      emit(
        state.copyWith(
          status: anyError ? SearchStatus.error : SearchStatus.success,
          groups: const [],
        ),
      );
    } else {
      emit(state.copyWith(status: SearchStatus.success, groups: List.of(acc)));
    }
  }

  /// Past searches that contain [query] (case-insensitive), newest-first.
  List<String> _historyMatches(String query) {
    final l = query.toLowerCase();
    return _history
        .recent()
        .where((e) {
          final el = e.toLowerCase();
          return el != l && el.contains(l);
        })
        .take(4)
        .toList();
  }

  /// History first (already de-duped against itself), then live titles that
  /// aren't already present. Capped so the list stays compact.
  List<String> _merge(List<String> history, List<String> live) {
    final out = <String>[...history];
    final seen = {for (final h in history) h.toLowerCase()};
    for (final t in live) {
      if (seen.add(t.toLowerCase())) out.add(t);
      if (out.length >= 8) break;
    }
    return out;
  }

  /// Stores the per-source Aniyomi filter selection and re-fetches that one
  /// source with the updated selection applied.
  ///
  /// An empty [SearchSourceFiltersApplied.selectionJson] clears the entry,
  /// reverting the source to unfiltered results on the next search.
  Future<void> _onSourceFiltersApplied(
    SearchSourceFiltersApplied event,
    Emitter<SearchState> emit,
  ) async {
    final map = Map<String, String>.of(state.aniFiltersBySource);
    if (event.selectionJson.isEmpty) {
      map.remove(event.sourceId);
    } else {
      map[event.sourceId] = event.selectionJson;
    }
    emit(state.copyWith(aniFiltersBySource: map));
    final q = state.query.trim();
    if (q.isEmpty) {
      // Filters with an empty search box = browse. The idle screen's "Top
      // picks" comes from home(), which takes no filters, so without this the
      // selection was stored and then silently ignored — exactly what a source's
      // Sort/Genre/Year filters are for. Aniyomi treats no-query-plus-filters as
      // an ordinary search and extensions implement it that way, so we ask for
      // the same thing.
      await _browseWithFilters(event.sourceId, map[event.sourceId], emit);
      return;
    }
    final res = await _repo.searchStatus(
      q,
      sourceId: event.sourceId,
      filtersJson: map[event.sourceId],
    );
    if (isClosed || state.query.trim() != q) return;
    final groups = List<SourceResultGroup>.of(state.groups);
    final idx = groups.indexWhere((g) => g.sourceId == event.sourceId);
    if (res.items.isEmpty) {
      if (idx >= 0) groups.removeAt(idx);
    } else {
      final arrival = idx >= 0 ? groups[idx].arrivalIndex : groups.length;
      final g = SourceResultGroup(
        sourceId: event.sourceId,
        sourceName: _repo.displayName(event.sourceId),
        items: res.items,
        arrivalIndex: arrival,
      );
      if (idx >= 0) {
        groups[idx] = g;
      } else {
        groups.add(g);
      }
    }
    emit(state.copyWith(groups: groups));
  }

  /// Runs an empty-query search carrying only [filtersJson] and parks the
  /// results in `filteredBrowse`, which the idle screen shows in place of "Top
  /// picks". A cleared selection (null/empty) drops straight back to the normal
  /// idle view instead of issuing a pointless unfiltered search.
  ///
  /// Failures clear the browse rather than surfacing an error: this runs off a
  /// filter tap on the idle screen, and a source that rejects empty queries
  /// should leave the user on "Top picks", not on an error page.
  Future<void> _browseWithFilters(
    String sourceId,
    String? filtersJson,
    Emitter<SearchState> emit,
  ) async {
    if (filtersJson == null || filtersJson.isEmpty) {
      emit(
        state.copyWith(filteredBrowse: const [], filteredBrowseSourceId: ''),
      );
      return;
    }
    try {
      final res = await _repo.searchStatus(
        '',
        sourceId: sourceId,
        filtersJson: filtersJson,
      );
      if (isClosed || state.query.trim().isNotEmpty) return;
      emit(
        state.copyWith(
          filteredBrowse: res.items,
          filteredBrowseSourceId: res.items.isEmpty ? '' : sourceId,
          filteredBrowsePage: 1,
          filteredBrowseLoadingMore: false,
          filteredBrowseAtEnd: false,
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        state.copyWith(filteredBrowse: const [], filteredBrowseSourceId: ''),
      );
    }
  }

  /// Appends the next page of a filters-only browse (infinite scroll).
  ///
  /// A source that returns nothing, or only titles already on screen, is out of
  /// pages — some sources repeat the first page forever rather than 404ing, so
  /// the dedupe result decides, not just an empty list.
  Future<void> _onFilteredBrowseMore(
    SearchFilteredBrowseMore event,
    Emitter<SearchState> emit,
  ) async {
    if (!state.canLoadMoreFilteredBrowse) return;
    final sourceId = state.filteredBrowseSourceId;
    final filtersJson = state.aniFiltersBySource[sourceId];
    if (sourceId.isEmpty || filtersJson == null || filtersJson.isEmpty) return;

    final nextPage = state.filteredBrowsePage + 1;
    emit(state.copyWith(filteredBrowseLoadingMore: true));
    try {
      final res = await _repo.searchStatus(
        '',
        sourceId: sourceId,
        filtersJson: filtersJson,
        page: nextPage,
      );
      if (isClosed) return;
      final seen = {for (final i in state.filteredBrowse) i.url};
      final fresh = res.items.where((i) => !seen.contains(i.url)).toList();
      emit(
        state.copyWith(
          filteredBrowse: fresh.isEmpty
              ? state.filteredBrowse
              : [...state.filteredBrowse, ...fresh],
          filteredBrowsePage: nextPage,
          filteredBrowseLoadingMore: false,
          filteredBrowseAtEnd: fresh.isEmpty,
        ),
      );
    } catch (_) {
      if (isClosed) return;
      // Stop paging on failure rather than retrying on every scroll tick.
      emit(
        state.copyWith(
          filteredBrowseLoadingMore: false,
          filteredBrowseAtEnd: true,
        ),
      );
    }
  }

  /// Mode switched — drop everything the previous mode fetched. The query text
  /// is kept so re-running it in the new mode is one tap, but nothing is
  /// searched automatically: an all-sources fan-out is expensive and the user
  /// didn't ask for it by flipping mode.
  void _onModeChanged(SearchModeChanged event, Emitter<SearchState> emit) {
    _runGen++; // orphan any in-flight fan-out from the old mode
    emit(
      state.copyWith(
        status: SearchStatus.idle,
        groups: const [],
        respondedSources: const {},
        suggestions: const [],
        sourceFilter: kAllSources,
        ecosystem: SearchEcosystem.all,
      ),
    );
  }

  @override
  Future<void> close() {
    _suggestDebounce?.cancel();
    _modeSub?.cancel();
    return super.close();
  }
}
