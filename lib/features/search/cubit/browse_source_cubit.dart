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
    this.filtersJson = '',
    this.query = '',
    this.page = 1,
    this.loadingMore = false,
    this.atEnd = false,
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

  /// The source's own filter selection currently applied, as selection JSON.
  /// Empty means unfiltered. Kept so the sheet reopens on the last choice and
  /// the app bar can show the filter as active.
  final String filtersJson;

  /// The query behind [searchResults], kept so the next page can ask for the
  /// same thing.
  final String query;

  /// Last page fetched. The first request is page 1.
  final int page;
  final bool loadingMore;

  /// No more pages: an empty page, or one whose items we already had. Sources
  /// rarely report a total, so the end is something you discover.
  final bool atEnd;

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
    emit(
      BrowseSourceState(
        sections: state.sections,
        loading: false,
        searching: true,
      ),
    );
    try {
      final results = await _repo.search(q, sourceId: sourceId);
      if (isClosed) return;
      emit(
        BrowseSourceState(
          sections: state.sections,
          loading: false,
          searchResults: results,
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        BrowseSourceState(
          sections: state.sections,
          loading: false,
          searchFailed: true,
        ),
      );
    }
  }

  /// Applies the source's own filters (genre, sort, status) with no query.
  ///
  /// [home] takes no filters, so a filtered browse has to go through search.
  /// That isn't a workaround: the extensions treat no-query-plus-filters as an
  /// ordinary search and implement it that way, so we ask for the same thing.
  Future<void> applyFilters(String filtersJson) async {
    if (filtersJson.isEmpty) {
      clearSearch();
      return;
    }
    emit(
      BrowseSourceState(
        sections: state.sections,
        loading: false,
        searching: true,
        filtersJson: filtersJson,
      ),
    );
    try {
      final res = await _repo.searchStatus(
        '',
        sourceId: sourceId,
        filtersJson: filtersJson,
      );
      if (isClosed) return;
      emit(
        BrowseSourceState(
          sections: state.sections,
          loading: false,
          searchResults: res.items,
          filtersJson: filtersJson,
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        BrowseSourceState(
          sections: state.sections,
          loading: false,
          searchFailed: true,
          filtersJson: filtersJson,
        ),
      );
    }
  }

  /// Appends the next page of whatever is on screen — a filtered browse or a
  /// text search, both of which the source pages the same way.
  ///
  /// Stops on an empty page OR one that adds nothing new: sources rarely say
  /// how many pages exist, and several answer an out-of-range page with the
  /// first one again, which would otherwise scroll forever.
  Future<void> loadMore() async {
    if (state.loadingMore || state.atEnd || !state.isSearchActive) return;
    final current = state.searchResults ?? const [];
    emit(_copy(loadingMore: true));
    try {
      final res = await _repo.searchStatus(
        state.query,
        sourceId: sourceId,
        filtersJson: state.filtersJson.isEmpty ? null : state.filtersJson,
        page: state.page + 1,
      );
      if (isClosed) return;
      final seen = {for (final i in current) i.url};
      final fresh = [
        for (final i in res.items)
          if (seen.add(i.url)) i,
      ];
      emit(_copy(
        searchResults: [...current, ...fresh],
        page: state.page + 1,
        loadingMore: false,
        atEnd: fresh.isEmpty,
      ));
    } catch (_) {
      if (isClosed) return;
      // A failed page is not the end — the next scroll may work.
      emit(_copy(loadingMore: false));
    }
  }

  BrowseSourceState _copy({
    List<MediaItem>? searchResults,
    int? page,
    bool? loadingMore,
    bool? atEnd,
  }) => BrowseSourceState(
    sections: state.sections,
    loading: false,
    searchResults: searchResults ?? state.searchResults,
    filtersJson: state.filtersJson,
    query: state.query,
    page: page ?? state.page,
    loadingMore: loadingMore ?? state.loadingMore,
    atEnd: atEnd ?? state.atEnd,
  );

  /// Drops the search results and returns to the already-loaded catalogue
  /// rows — never re-fetches [home].
  void clearSearch() {
    emit(
      BrowseSourceState(
        sections: state.sections,
        loading: state.loading,
        failed: state.failed,
      ),
    );
  }
}
