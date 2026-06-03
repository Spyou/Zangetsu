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

/// Results from one source (provider), for grouped cross-source search.
class SourceResultGroup extends Equatable {
  const SourceResultGroup({
    required this.sourceId,
    required this.sourceName,
    required this.items,
  });

  final String sourceId;
  final String sourceName;
  final List<MediaItem> items;

  @override
  List<Object?> get props => [sourceId, sourceName, items];
}

/// Sentinel source-filter value meaning "all sources".
const String kAllSources = '__all__';

class SearchState extends Equatable {
  final SearchStatus status;
  final String query;

  /// Per-source result groups (cross-source search).
  final List<SourceResultGroup> groups;

  /// Active source-filter chip: [kAllSources] or a specific sourceId.
  final String sourceFilter;

  final SearchSort sort;
  final String? error;

  /// Trending titles for the idle screen (loaded once).
  final List<MediaItem> trending;

  const SearchState({
    this.status = SearchStatus.idle,
    this.query = '',
    this.groups = const [],
    this.sourceFilter = kAllSources,
    this.sort = SearchSort.bestMatch,
    this.error,
    this.trending = const [],
  });

  /// Total results across every source.
  int get totalCount =>
      groups.fold(0, (sum, g) => sum + g.items.length);

  /// Results for the selected source filter, with the current sort applied.
  List<MediaItem> get visibleResults {
    final base = <MediaItem>[
      for (final g in groups)
        if (sourceFilter == kAllSources || g.sourceId == sourceFilter)
          ...g.items,
    ];
    switch (sort) {
      case SearchSort.bestMatch:
        return base;
      case SearchSort.titleAsc:
        return base
          ..sort((a, b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case SearchSort.titleDesc:
        return base
          ..sort((a, b) =>
              b.title.toLowerCase().compareTo(a.title.toLowerCase()));
    }
  }

  SearchState copyWith({
    SearchStatus? status,
    String? query,
    List<SourceResultGroup>? groups,
    String? sourceFilter,
    SearchSort? sort,
    String? error,
    bool clearError = false,
    List<MediaItem>? trending,
  }) => SearchState(
    status: status ?? this.status,
    query: query ?? this.query,
    groups: groups ?? this.groups,
    sourceFilter: sourceFilter ?? this.sourceFilter,
    sort: sort ?? this.sort,
    error: clearError ? null : (error ?? this.error),
    trending: trending ?? this.trending,
  );

  @override
  List<Object?> get props =>
      [status, query, groups, sourceFilter, sort, error, trending];
}
