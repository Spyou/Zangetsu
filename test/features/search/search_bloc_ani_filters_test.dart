import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/features/search/bloc/search_bloc.dart';
import 'package:watch_app/features/search/bloc/search_event.dart';

// ---------------------------------------------------------------------------
// Fakes — all use `extends`/`implements` to bypass native-plugin constructors
// ---------------------------------------------------------------------------

/// Fake prefs: overrides all Hive-accessing getters so no box needs to be open.
class _FakeSearchPrefs extends SearchPrefs {
  @override
  String? get contentFilterName => null;
  @override
  String? get audioFilterName => null;
  @override
  String? get statusFilterName => null;
  @override
  String? get sortName => null;
  @override
  String? get genre => null;
  @override
  int? get decade => null;
  @override
  bool get currentSourceOnly => true;

  @override
  Future<void> setContentFilterName(String name) async {}
  @override
  Future<void> setAudioFilterName(String name) async {}
  @override
  Future<void> setStatusFilterName(String name) async {}
  @override
  Future<void> setSortName(String name) async {}
  @override
  Future<void> setGenre(String? genre) async {}
  @override
  Future<void> setDecade(int? decade) async {}
  @override
  Future<void> setCurrentSourceOnly(bool value) async {}
}

/// Fake history: no Hive box needed.
class _FakeSearchHistory extends SearchHistory {
  @override
  List<String> recent() => [];
  @override
  Future<void> add(String query) async {}
  @override
  Future<void> remove(String query) async {}
  @override
  Future<void> clear() async {}
}

/// Fake title-suggestion service: returns empty instantly (no network).
class _FakeSuggestions extends TitleSuggestionService {
  _FakeSuggestions() : super(Dio());

  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async => [];
}

/// Fake repository: `implements` (NOT `extends`) so the SourceRepository
/// constructor — which requires ProviderManager/CloudStreamManager/etc. — is
/// never called. Only the members touched by `_onSourceFiltersApplied` carry
/// real logic; everything else throws UnimplementedError.
class _FakeRepo implements SourceRepository {
  /// The items returned by the next `searchStatus` call.
  List<MediaItem> searchItems = const [];

  /// Captured args from the most recent `searchStatus` call.
  String? capturedSourceId;
  String? capturedFiltersJson;
  String? capturedQuery;
  int? capturedPage;

  /// Per-page canned results, consumed as each page is requested. Anything not
  /// listed falls back to [searchItems].
  Map<int, List<MediaItem>> pagedItems = {};

  /// How many times `searchStatus` has been called — lets a test assert that a
  /// path issues NO request at all, which an args check can't distinguish from
  /// a request that happened to carry the same args as the previous one.
  int searchCalls = 0;

  /// When set, `searchStatus` throws it instead of returning.
  Object? throwOnSearch;

  // ── Members used by the handler under test ─────────────────────────────────

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    searchCalls++;
    capturedSourceId = sourceId;
    capturedFiltersJson = filtersJson;
    capturedQuery = query;
    capturedPage = page;
    final queued = pagedItems.remove(page);
    if (queued != null) searchItems = queued;
    if (throwOnSearch != null) throw throwOnSearch!;
    return (
      items: searchItems,
      outcome: searchItems.isEmpty ? SourceOutcome.empty : SourceOutcome.ok,
    );
  }

  @override
  String displayName(String sourceId) => 'Fake Source';

  @override
  List<({String id, String name})> get loadedSources => [];

  @override
  String get sourceId => 'ani:1';

  // ── Everything else — never called in these tests ─────────────────────────

  // Any SourceRepository member not overridden here is never exercised by
  // these tests; route it to a clear failure so the fake doesn't have to track
  // every member the interface grows.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  bool hasSource(String sourceId) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
    String? sourceId,
  }) => throw UnimplementedError();

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) =>
      throw UnimplementedError();

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> browseMore(BrowseMore more, int page) =>
      throw UnimplementedError();

  @override
  Future<List<AniyomiFilter>> aniFilters(String sourceId) =>
      throw UnimplementedError();

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) => throw UnimplementedError();

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) => throw UnimplementedError();

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) => throw UnimplementedError();

  @override
  void invalidateSources(
    String episodeUrl, {
    String? sourceId,
    bool includePrefetch = false,
  }) => throw UnimplementedError();

  @override
  void prefetch(String episodeUrl, {String? sourceId}) =>
      throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A distinct item per (sourceId, title). The url has to vary with the title:
/// paging dedupes by url, so a fixed url would make every page look like a
/// repeat of the first.
MediaItem _fakeItem(String sourceId, {String title = 'Naruto'}) => MediaItem(
  id: 'id-$sourceId-$title',
  title: title,
  url: 'https://example.com/$sourceId/${title.toLowerCase()}',
  type: ProviderType.anime,
  sourceId: sourceId,
);

/// Seeds a non-empty query into [bloc] and drains the resulting state changes.
Future<void> _seedQuery(SearchBloc bloc, String query) async {
  bloc.add(SearchQueryChanged(query));
  // Allow the synchronous emissions from _onQueryChanged to be processed, then
  // wait for the next Future boundary (the async searchStatus call later).
  await Future<void>.delayed(Duration.zero);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late _FakeRepo repo;
  late SearchBloc bloc;

  setUp(() {
    repo = _FakeRepo();
    bloc = SearchBloc(
      repo: repo,
      history: _FakeSearchHistory(),
      prefs: _FakeSearchPrefs(),
      suggestions: _FakeSuggestions(),
    );
  });

  tearDown(() async {
    // close() cancels the suggestion debounce timer — no timer leaks.
    await bloc.close();
  });

  group('SearchBloc._onSourceFiltersApplied', () {
    // ── Test 1: filter stored + searchStatus called with filtersJson ─────────

    test(
      'stores selectionJson in aniFiltersBySource and forwards it to searchStatus',
      () async {
        await _seedQuery(bloc, 'naruto');

        repo.searchItems = [_fakeItem('ani:1')];

        bloc.add(const SearchSourceFiltersApplied('ani:1', '["sel"]'));
        // One microtask loop lets the first synchronous emit complete; a second
        // allows the awaited searchStatus future to resolve.
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          bloc.state.aniFiltersBySource['ani:1'],
          '["sel"]',
          reason: 'filter should be stored under the source id',
        );
        expect(
          repo.capturedSourceId,
          'ani:1',
          reason: 'searchStatus should receive the correct sourceId',
        );
        expect(
          repo.capturedFiltersJson,
          '["sel"]',
          reason: 'non-empty selection must be forwarded as filtersJson',
        );
      },
    );

    // ── Test 2: empty selection clears the entry and passes null filtersJson ─

    test(
      'empty selectionJson removes the entry and calls searchStatus with null filtersJson',
      () async {
        await _seedQuery(bloc, 'naruto');

        // Build up a filter entry first.
        repo.searchItems = [_fakeItem('ani:1')];
        bloc.add(const SearchSourceFiltersApplied('ani:1', '["sel"]'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(bloc.state.aniFiltersBySource, contains('ani:1'));

        // Clear it.
        repo.capturedFiltersJson = 'sentinel_should_be_overwritten';
        bloc.add(const SearchSourceFiltersApplied('ani:1', ''));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          bloc.state.aniFiltersBySource,
          isNot(contains('ani:1')),
          reason: 'empty selection should remove the source entry',
        );
        expect(
          repo.capturedFiltersJson,
          isNull,
          reason: 'cleared entry must be forwarded as null filtersJson',
        );
      },
    );

    // ── Test 3a: group is APPENDED when none existed ─────────────────────────

    test(
      'group is appended when searchStatus returns items and no group existed',
      () async {
        await _seedQuery(bloc, 'naruto');
        expect(bloc.state.groups, isEmpty);

        repo.searchItems = [_fakeItem('ani:1')];
        bloc.add(const SearchSourceFiltersApplied('ani:1', '["s1"]'));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(bloc.state.groups, hasLength(1));
        expect(bloc.state.groups.first.sourceId, 'ani:1');
        expect(
          bloc.state.groups.first.arrivalIndex,
          0,
          reason: 'first appended group gets arrivalIndex 0',
        );
      },
    );

    // ── Test 3b: group is REPLACED and arrivalIndex preserved ────────────────

    test(
      'group is replaced in-place on subsequent apply, preserving arrivalIndex',
      () async {
        await _seedQuery(bloc, 'naruto');

        // Seed the group.
        repo.searchItems = [_fakeItem('ani:1', title: 'Naruto')];
        bloc.add(const SearchSourceFiltersApplied('ani:1', '["s1"]'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final originalArrival = bloc.state.groups.first.arrivalIndex;

        // Replace with different items.
        repo.searchItems = [_fakeItem('ani:1', title: 'Bleach')];
        bloc.add(const SearchSourceFiltersApplied('ani:1', '["s2"]'));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          bloc.state.groups,
          hasLength(1),
          reason: 'replace should not duplicate the group',
        );
        expect(bloc.state.groups.first.items.first.title, 'Bleach');
        expect(
          bloc.state.groups.first.arrivalIndex,
          originalArrival,
          reason: 'arrivalIndex must be preserved on replace',
        );
      },
    );

    // ── Test 3c: group is REMOVED when searchStatus returns empty items ───────

    test(
      'group is removed when searchStatus returns an empty item list',
      () async {
        await _seedQuery(bloc, 'naruto');

        // Seed a group.
        repo.searchItems = [_fakeItem('ani:1')];
        bloc.add(const SearchSourceFiltersApplied('ani:1', '["s1"]'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(bloc.state.groups, hasLength(1));

        // Return empty → group removed.
        repo.searchItems = [];
        bloc.add(const SearchSourceFiltersApplied('ani:1', '["s2"]'));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          bloc.state.groups,
          isEmpty,
          reason: 'group should be removed when there are no results',
        );
      },
    );
  });

  // Filters set with an EMPTY search box. This used to store the selection and
  // return without fetching anything, so a source's Sort/Genre/Year filters —
  // which exist for browsing, not searching — appeared to do nothing at all.
  group('SearchBloc._onSourceFiltersApplied with no query (filtered browse)', () {
    test('searches with an empty query and the filters, and shows the results',
        () async {
      expect(bloc.state.query, isEmpty, reason: 'no query seeded');
      repo.searchItems = [_fakeItem('ani:1', title: 'Action Anime')];

      bloc.add(const SearchSourceFiltersApplied('ani:1', '["genre:action"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        repo.searchCalls,
        1,
        reason: 'an empty search box must still issue a filtered request',
      );
      expect(repo.capturedQuery, '');
      expect(repo.capturedFiltersJson, '["genre:action"]');
      expect(repo.capturedSourceId, 'ani:1');
      expect(bloc.state.filteredBrowse.first.title, 'Action Anime');
      expect(bloc.state.filteredBrowseSourceId, 'ani:1');
      expect(bloc.state.hasFilteredBrowse, isTrue);
    });

    test('leaves the normal search groups alone', () async {
      repo.searchItems = [_fakeItem('ani:1')];
      bloc.add(const SearchSourceFiltersApplied('ani:1', '["s"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        bloc.state.groups,
        isEmpty,
        reason: 'a filters-only browse is not a search result group',
      );
    });

    test('clearing the filters drops the browse without issuing a request',
        () async {
      repo.searchItems = [_fakeItem('ani:1')];
      bloc.add(const SearchSourceFiltersApplied('ani:1', '["s"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(bloc.state.hasFilteredBrowse, isTrue);

      final callsBefore = repo.searchCalls;
      bloc.add(const SearchSourceFiltersApplied('ani:1', ''));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.filteredBrowse, isEmpty);
      expect(bloc.state.filteredBrowseSourceId, isEmpty);
      expect(
        repo.searchCalls,
        callsBefore,
        reason: 'clearing must not fire an unfiltered empty-query search',
      );
    });

    test('no results leaves the browse inactive so Top picks stays', () async {
      repo.searchItems = [];
      bloc.add(const SearchSourceFiltersApplied('ani:1', '["s"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.filteredBrowse, isEmpty);
      expect(bloc.state.filteredBrowseSourceId, isEmpty);
      expect(bloc.state.hasFilteredBrowse, isFalse);
    });

    test('a failing source falls back to the idle view instead of erroring',
        () async {
      repo.throwOnSearch = StateError('source rejected empty query');

      bloc.add(const SearchSourceFiltersApplied('ani:1', '["s"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.hasFilteredBrowse, isFalse);
      expect(
        bloc.state.aniFiltersBySource['ani:1'],
        '["s"]',
        reason: 'the selection is still remembered even if the fetch failed',
      );
    });

    test('a query still takes the normal grouped path, not the browse path',
        () async {
      await _seedQuery(bloc, 'naruto');
      repo.searchItems = [_fakeItem('ani:1')];

      bloc.add(const SearchSourceFiltersApplied('ani:1', '["s"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.capturedQuery, 'naruto');
      expect(bloc.state.groups, hasLength(1));
      expect(
        bloc.state.hasFilteredBrowse,
        isFalse,
        reason: 'browse is for the empty-query case only',
      );
    });
  });

  group('SearchFilteredBrowseMore (infinite scroll)', () {
    /// Starts a browse whose first page is [first].
    Future<void> startBrowse(List<MediaItem> first) async {
      repo.searchItems = first;
      bloc.add(const SearchSourceFiltersApplied('ani:1', '["s"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    test('appends the next page and advances the page counter', () async {
      await startBrowse([_fakeItem('ani:1', title: 'One')]);
      expect(bloc.state.filteredBrowsePage, 1);

      repo.searchItems = [_fakeItem('ani:1', title: 'Two')];
      bloc.add(const SearchFilteredBrowseMore());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.capturedPage, 2, reason: 'must ask the source for page 2');
      expect(repo.capturedQuery, '', reason: 'still a filters-only browse');
      expect(repo.capturedFiltersJson, '["s"]');
      expect(
        bloc.state.filteredBrowse.map((i) => i.title),
        ['One', 'Two'],
        reason: 'page 2 appends, it does not replace',
      );
      expect(bloc.state.filteredBrowsePage, 2);
      expect(bloc.state.filteredBrowseLoadingMore, isFalse);
      expect(bloc.state.filteredBrowseAtEnd, isFalse);
    });

    test('an empty page ends paging', () async {
      await startBrowse([_fakeItem('ani:1', title: 'One')]);

      repo.searchItems = [];
      bloc.add(const SearchFilteredBrowseMore());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.filteredBrowseAtEnd, isTrue);
      expect(bloc.state.canLoadMoreFilteredBrowse, isFalse);
      expect(bloc.state.filteredBrowse, hasLength(1));
    });

    test('a source that repeats page 1 forever ends paging instead of looping',
        () async {
      final page1 = [_fakeItem('ani:1', title: 'One')];
      await startBrowse(page1);

      // Same item back again — some sources ignore the page param entirely.
      repo.searchItems = page1;
      bloc.add(const SearchFilteredBrowseMore());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        bloc.state.filteredBrowse,
        hasLength(1),
        reason: 'duplicates must not be appended',
      );
      expect(
        bloc.state.filteredBrowseAtEnd,
        isTrue,
        reason: 'nothing new means the source is out of pages',
      );
    });

    test('does nothing when no browse is active', () async {
      expect(bloc.state.hasFilteredBrowse, isFalse);
      final before = repo.searchCalls;

      bloc.add(const SearchFilteredBrowseMore());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(repo.searchCalls, before);
    });

    test('stops paging when a page fails rather than retrying every scroll',
        () async {
      await startBrowse([_fakeItem('ani:1', title: 'One')]);

      repo.throwOnSearch = StateError('boom');
      bloc.add(const SearchFilteredBrowseMore());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.filteredBrowseAtEnd, isTrue);
      expect(bloc.state.filteredBrowseLoadingMore, isFalse);
      expect(
        bloc.state.filteredBrowse,
        hasLength(1),
        reason: 'existing results survive a failed page',
      );
    });

    test('re-applying filters resets paging to page 1', () async {
      await startBrowse([_fakeItem('ani:1', title: 'One')]);
      repo.searchItems = [_fakeItem('ani:1', title: 'Two')];
      bloc.add(const SearchFilteredBrowseMore());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(bloc.state.filteredBrowsePage, 2);

      // New selection → fresh browse from the top.
      repo.searchItems = [_fakeItem('ani:1', title: 'Fresh')];
      bloc.add(const SearchSourceFiltersApplied('ani:1', '["other"]'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.filteredBrowsePage, 1);
      expect(bloc.state.filteredBrowseAtEnd, isFalse);
      expect(bloc.state.filteredBrowse.map((i) => i.title), ['Fresh']);
    });
  });
}
