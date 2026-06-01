import 'package:equatable/equatable.dart';

import '../../../core/models/media_item.dart';

enum SearchStatus { idle, loading, success, error }

enum SearchSort {
  bestMatch('Best match'),
  titleAsc('Title A–Z'),
  titleDesc('Title Z–A');

  const SearchSort(this.label);
  final String label;
}

class SearchState extends Equatable {
  final SearchStatus status;
  final String query;
  final List<MediaItem> results;
  final SearchSort sort;
  final String? error;

  const SearchState({
    this.status = SearchStatus.idle,
    this.query = '',
    this.results = const [],
    this.sort = SearchSort.bestMatch,
    this.error,
  });

  /// Results with the current sort applied (client-side).
  List<MediaItem> get sortedResults {
    switch (sort) {
      case SearchSort.bestMatch:
        return results;
      case SearchSort.titleAsc:
        return [...results]
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
      case SearchSort.titleDesc:
        return [...results]
          ..sort(
            (a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()),
          );
    }
  }

  SearchState copyWith({
    SearchStatus? status,
    String? query,
    List<MediaItem>? results,
    SearchSort? sort,
    String? error,
    bool clearError = false,
  }) => SearchState(
    status: status ?? this.status,
    query: query ?? this.query,
    results: results ?? this.results,
    sort: sort ?? this.sort,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [status, query, results, sort, error];
}
