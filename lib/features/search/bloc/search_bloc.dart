import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injector.dart';
import '../../../core/models/media_item.dart';
import '../../../core/playback/search_history.dart';
import '../../../core/playback/search_prefs.dart';
import '../../../core/playback/search_source_prefs.dart';
import '../../../core/repository/source_repository.dart';
import '../../../core/search/title_suggestion_service.dart';
import '../../../core/state/active_source_cubit.dart';
import 'search_event.dart';
import 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc({
    required SourceRepository repo,
    required SearchHistory history,
    SearchPrefs? prefs,
    TitleSuggestionService? suggestions,
  })  : _repo = repo,
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
    on<SearchContentFilterChanged>(_onContentFilterChanged);
    on<SearchGenreFilterChanged>(_onGenreFilterChanged);
    on<SearchDecadeFilterChanged>(_onDecadeFilterChanged);
    on<SearchRunRequested>(_onRunRequested);
    on<SearchSubmitted>(_onSubmitted);
  }

  final SourceRepository _repo;
  final SearchHistory _history;
  final SearchPrefs _prefs;
  final TitleSuggestionService _suggestions;

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
    return SearchState(
      contentFilter: content,
      sort: sort,
      genreFilter: prefs.genre,
      decadeFilter: prefs.decade,
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
    } catch (_) {/* trending is best-effort */}
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
      emit(state.copyWith(
        groups: const [],
        suggestions: const [],
        status: SearchStatus.idle,
        clearError: true,
      ));
      return;
    }

    // History matches are instant; show them immediately. If the field has
    // drifted away from the last-searched query, leave the results view (back
    // to idle) so the suggestion list takes over while typing the next query.
    final historyMatches = _historyMatches(trimmed);
    final driftedFromResults = state.status == SearchStatus.success &&
        trimmed.toLowerCase() != _lastRunQuery.toLowerCase();
    emit(state.copyWith(
      suggestions: historyMatches,
      status: driftedFromResults ? SearchStatus.idle : null,
      groups: driftedFromResults ? const [] : null,
    ));

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
    emit(state.copyWith(
      currentSourceOnly: event.currentSourceOnly,
      sourceFilter: kAllSources,
    ));
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

  void _onContentFilterChanged(
    SearchContentFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    // Switching content type can hide the active source group; fall back to
    // "All sources" so the user never lands on an empty filtered view.
    emit(state.copyWith(
      contentFilter: event.filter,
      sourceFilter: kAllSources,
    ));
    _prefs.setContentFilterName(event.filter.name);
  }

  void _onGenreFilterChanged(
    SearchGenreFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    emit(state.copyWith(
      genreFilter: event.genre,
      clearGenreFilter: event.genre == null,
      sourceFilter: kAllSources,
    ));
    _prefs.setGenre(event.genre);
  }

  void _onDecadeFilterChanged(
    SearchDecadeFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    emit(state.copyWith(
      decadeFilter: event.decade,
      clearDecadeFilter: event.decade == null,
      sourceFilter: kAllSources,
    ));
    _prefs.setDecade(event.decade);
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
    // Reset only the per-search source chip — the user's remembered sort and
    // content/genre/decade filters persist across searches (and screen opens).
    emit(state.copyWith(
      query: q,
      suggestions: const [],
      sourceFilter: kAllSources,
    ));
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
    _lastRunQuery = q;
    _history.add(q);

    emit(state.copyWith(
      status: SearchStatus.loading,
      groups: const [],
      clearError: true,
    ));

    // Choose the sources to query. In current-source-only mode that's JUST the
    // active Home source (read live, so a later source switch is picked up). In
    // all-sources mode it's every loaded source EXCEPT the ones the user
    // switched off for search (search-only — doesn't affect Home use).
    final List<({String id, String name})> sources;
    if (state.currentSourceOnly) {
      final activeId = sl<ActiveSourceCubit>().state;
      sources = [(id: activeId, name: _repo.displayName(activeId))];
    } else {
      final prefs = sl<SearchSourcePrefs>();
      sources = _repo.loadedSources
          .where((s) => prefs.isIncluded(s.id))
          .toList();
    }
    if (sources.isEmpty) {
      emit(state.copyWith(status: SearchStatus.error));
      return;
    }

    final acc = <SourceResultGroup>[];
    var anyError = false;
    // Monotonic arrival counter: the Nth source to return non-empty results gets
    // arrivalIndex N, so sections render fastest-first (CloudStream-style).
    var arrived = 0;

    await Future.wait(sources.map((s) async {
      try {
        final r = await _repo.search(q, sourceId: s.id);
        if (isClosed || state.query.trim() != q) return; // superseded/closed
        if (r.isNotEmpty) {
          acc.add(SourceResultGroup(
            sourceId: s.id,
            sourceName: s.name,
            items: r,
            arrivalIndex: arrived++,
          ));
          emit(state.copyWith(
            status: SearchStatus.success,
            groups: List.of(acc),
          ));
        }
      } catch (_) {
        anyError = true;
      }
    }));

    if (isClosed || state.query.trim() != q) return;
    // Finalize: if nothing came back, surface error-or-empty appropriately.
    if (acc.isEmpty) {
      emit(state.copyWith(
        status: anyError ? SearchStatus.error : SearchStatus.success,
        groups: const [],
      ));
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

  @override
  Future<void> close() {
    _suggestDebounce?.cancel();
    return super.close();
  }
}
