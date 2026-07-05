import 'package:equatable/equatable.dart';

import 'search_state.dart';

abstract class SearchEvent extends Equatable {
  const SearchEvent();

  @override
  List<Object?> get props => [];
}

class SearchQueryChanged extends SearchEvent {
  const SearchQueryChanged(this.query);
  final String query;

  @override
  List<Object?> get props => [query];
}

class SearchSortChanged extends SearchEvent {
  const SearchSortChanged(this.sort);
  final SearchSort sort;

  @override
  List<Object?> get props => [sort];
}

class SearchSubmitted extends SearchEvent {
  const SearchSubmitted();
}

/// Explicitly runs the full multi-source search NOW (Enter / search icon /
/// suggestion tap). Optionally sets [query] first (used by suggestion taps so
/// the field and the query stay in sync). This is the ONLY trigger for the
/// heavy provider search — typing never starts it.
class SearchRunRequested extends SearchEvent {
  const SearchRunRequested([this.query]);
  final String? query;

  @override
  List<Object?> get props => [query];
}

/// Carries fresh autocomplete suggestions (history + live titles) to display
/// under the field while typing.
class SearchSuggestionsUpdated extends SearchEvent {
  const SearchSuggestionsUpdated(this.suggestions);
  final List<String> suggestions;

  @override
  List<Object?> get props => [suggestions];
}

/// Flips the search SCOPE between "current source only" and "all sources".
/// Persists the choice and re-runs the current query so it takes effect now.
class SearchScopeChanged extends SearchEvent {
  const SearchScopeChanged(this.currentSourceOnly);
  final bool currentSourceOnly;

  @override
  List<Object?> get props => [currentSourceOnly];
}

/// Switches the active source-filter chip ([kAllSources] or a sourceId).
class SearchSourceFilterChanged extends SearchEvent {
  const SearchSourceFilterChanged(this.sourceId);
  final String sourceId;

  @override
  List<Object?> get props => [sourceId];
}

/// Switches the active ecosystem tab (All / Zangetsu / CloudStream / Aniyomi).
/// Purely a view filter over the already-loaded groups — never re-runs search.
class SearchEcosystemChanged extends SearchEvent {
  const SearchEcosystemChanged(this.ecosystem);
  final SearchEcosystem ecosystem;

  @override
  List<Object?> get props => [ecosystem];
}

/// Switches the content-type filter (All / Anime / Movies & Series).
class SearchContentFilterChanged extends SearchEvent {
  const SearchContentFilterChanged(this.filter);
  final SearchContentFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// Sets (or clears, with null) the best-effort genre keyword filter.
class SearchGenreFilterChanged extends SearchEvent {
  const SearchGenreFilterChanged(this.genre);
  final String? genre;

  @override
  List<Object?> get props => [genre];
}

/// Sets (or clears, with null) the best-effort decade filter (start year).
class SearchDecadeFilterChanged extends SearchEvent {
  const SearchDecadeFilterChanged(this.decade);
  final int? decade;

  @override
  List<Object?> get props => [decade];
}

/// Fired once on open to load trending titles for the idle screen.
class SearchStarted extends SearchEvent {
  const SearchStarted();
}

/// Applies (or clears, with an empty [selectionJson]) the per-source Aniyomi
/// filter selection for [sourceId], then re-runs just that source's search.
class SearchSourceFiltersApplied extends SearchEvent {
  const SearchSourceFiltersApplied(this.sourceId, this.selectionJson);
  final String sourceId;
  final String selectionJson;

  @override
  List<Object?> get props => [sourceId, selectionJson];
}
