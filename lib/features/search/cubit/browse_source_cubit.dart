import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/home_section.dart';
import '../../../core/models/media_item.dart';
import '../../../core/repository/catalogue_repository.dart';

class BrowseSourceState {
  const BrowseSourceState({
    this.sections = const [],
    this.loading = true,
    this.failed = false,
    this.searching = false,
    this.searchFailed = false,
    this.searchResults,
  });

  final List<HomeSection> sections;
  final bool loading;

  /// The source threw. Distinct from "returned nothing" — an empty catalogue
  /// is a legitimate answer and must not be dressed up as a failure.
  final bool failed;

  /// A search request is in flight.
  final bool searching;

  /// The search itself threw. Distinct from [searchResults] coming back
  /// empty, same reasoning as [failed] vs. an empty catalogue.
  final bool searchFailed;

  /// Non-null once a search has completed — the screen shows these instead
  /// of [sections] until the query is cleared. Null means "browsing", not
  /// "searched and found nothing" (that's an empty, non-null list).
  final List<MediaItem>? searchResults;

  /// Whether the screen should be showing search results/spinner/failure
  /// instead of the catalogue rows.
  bool get isSearchActive => searching || searchFailed || searchResults != null;
}

/// One source's own catalogue. Deliberately holds a [CatalogueRepository] and
/// is constructed with `SourceRepository`, never the Z Mode router: this screen
/// browses a real source by definition.
class BrowseSourceCubit extends Cubit<BrowseSourceState> {
  BrowseSourceCubit({required CatalogueRepository repo, required this.sourceId})
      : _repo = repo,
        super(const BrowseSourceState());

  final CatalogueRepository _repo;
  final String sourceId;

  Future<void> load() async {
    emit(const BrowseSourceState());
    try {
      final sections = await _repo.home(sourceId: sourceId);
      if (isClosed) return;
      emit(BrowseSourceState(sections: sections, loading: false));
    } catch (_) {
      if (isClosed) return;
      emit(const BrowseSourceState(loading: false, failed: true));
    }
  }

  /// Runs a search scoped to [sourceId]. An empty/blank [query] just clears
  /// back to the catalogue, same as [clearSearch].
  Future<void> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      clearSearch();
      return;
    }
    emit(BrowseSourceState(
      sections: state.sections,
      loading: false,
      searching: true,
    ));
    try {
      final results = await _repo.search(q, sourceId: sourceId);
      if (isClosed) return;
      emit(BrowseSourceState(
        sections: state.sections,
        loading: false,
        searchResults: results,
      ));
    } catch (_) {
      if (isClosed) return;
      emit(BrowseSourceState(
        sections: state.sections,
        loading: false,
        searchFailed: true,
      ));
    }
  }

  /// Drops the search results and returns to the already-loaded catalogue
  /// rows — never re-fetches [home].
  void clearSearch() {
    emit(BrowseSourceState(
      sections: state.sections,
      loading: state.loading,
      failed: state.failed,
    ));
  }
}
