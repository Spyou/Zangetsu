import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/repository/source_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc({required SourceRepository repo})
    : _repo = repo,
      super(const SearchState()) {
    on<SearchQueryChanged>(_onQueryChanged);
    on<SearchSortChanged>(_onSortChanged);
    on<SearchSubmitted>(_onSubmitted);
  }

  final SourceRepository _repo;
  Timer? _debounce;

  void _onQueryChanged(SearchQueryChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(query: event.query, sort: SearchSort.bestMatch));
    _debounce?.cancel();

    if (event.query.trim().isEmpty) {
      emit(
        state.copyWith(
          results: const [],
          status: SearchStatus.idle,
          clearError: true,
        ),
      );
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

  Future<void> _onSubmitted(
    SearchSubmitted event,
    Emitter<SearchState> emit,
  ) async {
    final q = state.query.trim();
    if (q.isEmpty) return;

    emit(
      state.copyWith(
        status: SearchStatus.loading,
        results: const [],
        clearError: true,
      ),
    );

    try {
      final results = await _repo.search(q);
      emit(state.copyWith(status: SearchStatus.success, results: results));
    } catch (e) {
      emit(state.copyWith(status: SearchStatus.error, error: e.toString()));
    }
  }

  @override
  Future<void> close() {
    _debounce?.cancel();
    return super.close();
  }
}
