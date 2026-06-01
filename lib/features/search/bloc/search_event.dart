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
