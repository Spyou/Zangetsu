import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/playback/search_history.dart';
import '../../../core/repository/source_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc({required SourceRepository repo, required SearchHistory history})
    : _repo = repo,
      _history = history,
      super(const SearchState()) {
    on<SearchStarted>(_onStarted);
    on<SearchQueryChanged>(_onQueryChanged);
    on<SearchSortChanged>(_onSortChanged);
    on<SearchSourceFilterChanged>(_onSourceFilterChanged);
    on<SearchSubmitted>(_onSubmitted);
  }

  final SourceRepository _repo;
  final SearchHistory _history;
  Timer? _debounce;

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

  void _onQueryChanged(SearchQueryChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(
      query: event.query,
      sort: SearchSort.bestMatch,
      sourceFilter: kAllSources,
    ));
    _debounce?.cancel();

    if (event.query.trim().isEmpty) {
      emit(state.copyWith(
        groups: const [],
        status: SearchStatus.idle,
        clearError: true,
      ));
      return;
    }

    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => add(const SearchSubmitted()),
    );
  }

  void _onSortChanged(SearchSortChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(sort: event.sort));
  }

  void _onSourceFilterChanged(
    SearchSourceFilterChanged event,
    Emitter<SearchState> emit,
  ) {
    emit(state.copyWith(sourceFilter: event.sourceId));
  }

  /// Searches every loaded source concurrently and emits each source's results
  /// as soon as they arrive (fast sources show first; one slow/broken source
  /// never blocks the rest).
  Future<void> _onSubmitted(
    SearchSubmitted event,
    Emitter<SearchState> emit,
  ) async {
    final q = state.query.trim();
    if (q.isEmpty) return;
    _history.add(q);

    emit(state.copyWith(
      status: SearchStatus.loading,
      groups: const [],
      clearError: true,
    ));

    final sources = _repo.loadedSources;
    if (sources.isEmpty) {
      emit(state.copyWith(status: SearchStatus.error));
      return;
    }

    final acc = <SourceResultGroup>[];
    var anyError = false;

    await Future.wait(sources.map((s) async {
      try {
        final r = await _repo.search(q, sourceId: s.id);
        if (isClosed || state.query.trim() != q) return; // superseded/closed
        if (r.isNotEmpty) {
          acc.add(SourceResultGroup(
            sourceId: s.id,
            sourceName: s.name,
            items: r,
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

  @override
  Future<void> close() {
    _debounce?.cancel();
    return super.close();
  }
}
