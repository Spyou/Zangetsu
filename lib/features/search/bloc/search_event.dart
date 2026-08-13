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

/// Switches the audio filter (Any / Subbed / Dubbed). Anime mode only.
class SearchAudioFilterChanged extends SearchEvent {
  const SearchAudioFilterChanged(this.filter);
  final SearchAudioFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// Switches the publication-status filter (Any / Ongoing / Completed).
class SearchStatusFilterChanged extends SearchEvent {
  const SearchStatusFilterChanged(this.filter);
  final SearchStatusFilter filter;

  @override
  List<Object?> get props => [filter];
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

/// Requests the next page of a filters-only browse (infinite scroll), matching
/// how Aniyomi keeps paging a filtered browse as you scroll. Ignored when no
/// browse is active, one is already in flight, or the source ran out of pages.
class SearchFilteredBrowseMore extends SearchEvent {
  const SearchFilteredBrowseMore();

  @override
  List<Object?> get props => [];
}

/// The app-wide content mode changed (Streaming ⇄ Manga ⇄ Novel). Results only
/// make sense in the mode they were fetched in, so the bloc drops them; the
/// query text stays put, but nothing re-runs on its own.
class SearchModeChanged extends SearchEvent {
  const SearchModeChanged();

  @override
  List<Object?> get props => [];
}
