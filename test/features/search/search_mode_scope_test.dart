import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/bloc/search_bloc.dart';
import 'package:watch_app/features/search/bloc/search_event.dart';

// ---------------------------------------------------------------------------
// This pins the fix in SearchBloc._modeSources(): the all-sources fan-out in
// _runSearch used to search `_repo.loadedSources` unfiltered, so a manga-mode
// "all sources" search also queried anime/novel sources and the picker and
// the results disagreed. The fix narrows the fan-out to the active
// ContentMode, short-circuiting to the unfiltered list in anime mode (so
// anime/movie search — and TV, which has no mode switcher — is untouched).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Fakes — same shapes as test/features/search/search_bloc_ani_filters_test.dart
// ---------------------------------------------------------------------------

/// Fake prefs: overrides all Hive-accessing getters so no box needs to be
/// open. `currentSourceOnly => false` (unlike the ani-filters template) so the
/// bloc actually takes the all-sources fan-out branch under test.
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
  bool get currentSourceOnly => false;

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

/// Every source participates in search — the exclusion pref isn't what this
/// test is about.
class _FakeSearchSourcePrefs extends SearchSourcePrefs {
  @override
  bool isIncluded(String id) => true;
}

/// Every source reads as healthy and is never skipped — health-based
/// ordering/skipping isn't what this test is about.
class _FakeSourceHealthStore extends SourceHealthStore {
  @override
  SourceHealth statusOf(String id) => SourceHealth.ok;
  @override
  bool isSkippable(String id) => false;
  @override
  Future<void> record(String id, SourceOutcome outcome, {int? responseMs}) async {}
}

/// Fake repository: `implements` (NOT `extends`) so the SourceRepository
/// constructor — which requires ProviderManager/CloudStreamManager/etc. — is
/// never called. Records every sourceId `searchStatus` is actually called
/// with: that's the direct evidence of whether `_modeSources()` narrowed the
/// fan-out before it reached the network layer, since a source dropped by
/// mode-filtering never gets this far at all.
class _FakeRepo implements SourceRepository {
  /// What `loadedSources` reports as installed — set per test to a mixed
  /// anime+manga list.
  List<({String id, String name})> loadedSourcesSeed = const [];

  /// Items handed back for a given sourceId; missing entries return empty
  /// (no results, no error).
  final Map<String, List<MediaItem>> itemsFor = {};

  /// Every sourceId `searchStatus` was actually called with.
  final List<String> searchedSourceIds = [];

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    if (sourceId != null) searchedSourceIds.add(sourceId);
    final items = itemsFor[sourceId] ?? const <MediaItem>[];
    return (
      items: items,
      outcome: items.isEmpty ? SourceOutcome.empty : SourceOutcome.ok,
    );
  }

  @override
  String displayName(String sourceId) => sourceId;

  @override
  List<({String id, String name})> get loadedSources => loadedSourcesSeed;

  @override
  String get sourceId => 'ani:1';

  @override
  void syncSearchCache() {}

  // ── Everything else — never called in these tests ─────────────────────────
  // Any SourceRepository member not overridden here is never exercised by
  // these tests; route it to a clear failure so the fake doesn't have to
  // track every member the interface grows.
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

MediaItem _fakeItem(String sourceId) => MediaItem(
  id: 'id-$sourceId',
  title: 'Naruto',
  url: 'https://example.com/$sourceId',
  type: ProviderType.anime,
  sourceId: sourceId,
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;
  late ActiveSourceCubit activeSource;
  late ContentModeCubit modeCubit;
  late _FakeRepo repo;
  late SearchBloc bloc;

  setUp(() async {
    // ContentModeCubit.create() opens a real (temp) Hive box — its
    // constructor is private, so it can't be faked/subclassed from this file.
    tempDir = await Directory.systemTemp.createTemp('search_mode_scope_test');
    Hive.init(tempDir.path);

    activeSource = ActiveSourceCubit();
    modeCubit = await ContentModeCubit.create(activeSource);
    sl.registerSingleton<ContentModeCubit>(modeCubit);
    sl.registerSingleton<SearchSourcePrefs>(_FakeSearchSourcePrefs());
    sl.registerSingleton<SourceHealthStore>(_FakeSourceHealthStore());

    repo = _FakeRepo()
      ..loadedSourcesSeed = const [
        (id: 'ani:1', name: 'AniSource'),
        (id: 'mihon:1', name: 'MangaSource'),
      ]
      ..itemsFor['ani:1'] = [_fakeItem('ani:1')]
      ..itemsFor['mihon:1'] = [_fakeItem('mihon:1')];

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
    await modeCubit.close();
    await activeSource.close();
    await sl.reset();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('SearchBloc mode-scoped all-sources search', () {
    test(
      'manga mode: all-sources search does not query anime sources',
      () async {
        await modeCubit.setMode(ContentMode.manga);

        bloc.add(const SearchRunRequested('naruto'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          repo.searchedSourceIds,
          isNot(contains('ani:1')),
          reason:
              'a manga-mode all-sources search must not fan out to anime '
              'sources — that was the bug (bloc ignored the mode and searched '
              'everything in _repo.loadedSources)',
        );
        expect(
          repo.searchedSourceIds,
          contains('mihon:1'),
          reason: 'the manga source itself must still be searched',
        );
      },
    );

    test(
      'anime mode: manga and novel sources are not searched',
      () async {
        // Anime is already the restored default, but set it explicitly so
        // this test never depends on run order or a leftover Hive value.
        await modeCubit.setMode(ContentMode.anime);

        bloc.add(const SearchRunRequested('naruto'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // This assertion used to be inverted — it required anime mode to
        // search EVERY source, manga ones included, on the theory that any
        // narrowing would drop streaming sources. It doesn't: anime accepts
        // both anime and movie providers, and cs:/ani:/untyped ids all type as
        // anime, so the only thing filtering removes is exactly the manga and
        // novel sources that were leaking into anime results.
        expect(
          repo.searchedSourceIds.toSet(),
          {'ani:1'},
          reason:
              'anime mode must search video sources only — a mihon: source '
              'here is the manga/novel leak this test now guards against',
        );
      },
    );
  });

  group('SearchBloc.respondedSources (pending-skeleton bug fix)', () {
    // Pins the fix for a source that returns EMPTY results (or errors) never
    // leaving the Search screen's per-source skeleton on screen forever — see
    // SearchBloc._runSearch and SearchState.respondedSources. Before the fix,
    // `groups` was the ONLY signal the view had for "this source is done", and
    // a source only lands in `groups` when it has results — so an empty
    // response was indistinguishable from "hasn't answered yet".
    test(
      'a source that answers with zero results is still marked responded',
      () async {
        await modeCubit.setMode(ContentMode.manga);
        // A second manga source with no seeded items — searchStatus returns an
        // empty list for it, exactly like a real "no results" source.
        repo.loadedSourcesSeed = const [
          (id: 'mihon:1', name: 'MangaSource'),
          (id: 'mihon:2', name: 'EmptyMangaSource'),
        ];

        bloc.add(const SearchRunRequested('naruto'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          bloc.state.respondedSources,
          containsAll(['mihon:1', 'mihon:2']),
          reason:
              'both sources answered — mihon:2 with zero results — so '
              'neither should still read as pending once the run settles',
        );
        expect(
          bloc.state.groups.map((g) => g.sourceId),
          ['mihon:1'],
          reason:
              'mihon:2 produced no group (no results), unlike '
              'respondedSources, which tracks completion regardless of '
              'outcome',
        );
      },
    );
  });
}
