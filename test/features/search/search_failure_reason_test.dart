import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
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
import 'package:watch_app/features/search/bloc/search_state.dart';

// ---------------------------------------------------------------------------
// A source that fails used to disappear without a trace: the fan-out reduced
// every failure to one `anyError` bool, so the UI could only ever say "search
// failed — try again", and only when EVERY source had failed. These pin that
// the reason survives per source, and that Retry actually retries — a source
// that errored is marked dead, and _runSearch skips fresh-dead sources, so the
// retry has to clear the health mark or it silently declines to run.
// ---------------------------------------------------------------------------

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

class _FakeSuggestions extends TitleSuggestionService {
  _FakeSuggestions() : super(Dio());

  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async => [];
}

class _FakeSearchSourcePrefs extends SearchSourcePrefs {
  @override
  bool isIncluded(String id) => true;
}

/// Records health the way the real store does — a hard error marks a source
/// dead and therefore skippable — so the retry path is exercised against the
/// behaviour it actually has to work around.
class _FakeSourceHealthStore extends SourceHealthStore {
  final Set<String> dead = {};
  final List<String> cleared = [];

  @override
  SourceHealth statusOf(String id) =>
      dead.contains(id) ? SourceHealth.dead : SourceHealth.ok;

  @override
  bool isSkippable(String id) => dead.contains(id);

  @override
  Future<void> record(String id, SourceOutcome outcome, {int? responseMs}) async {
    if (outcome == SourceOutcome.error) {
      dead.add(id);
    } else {
      dead.remove(id);
    }
  }

  @override
  Future<void> clear(String id) async {
    cleared.add(id);
    dead.remove(id);
  }
}

class _FakeRepo implements SourceRepository {
  List<({String id, String name})> loadedSourcesSeed = const [];

  /// What each source hands back. Missing → empty-but-alive.
  final Map<String, ({List<MediaItem> items, SourceOutcome outcome})> resultFor =
      {};

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
    return resultFor[sourceId] ??
        (items: const <MediaItem>[], outcome: SourceOutcome.empty);
  }

  @override
  String displayName(String sourceId) => sourceId;

  @override
  List<({String id, String name})> get loadedSources => loadedSourcesSeed;

  @override
  String get sourceId => 'ani:1';

  @override
  void syncSearchCache() {}

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

MediaItem _item(String sourceId) => MediaItem(
  id: 'id-$sourceId',
  title: 'Naruto',
  url: 'https://example.com/$sourceId',
  type: ProviderType.anime,
  sourceId: sourceId,
);

void main() {
  late Directory tempDir;
  late ActiveSourceCubit activeSource;
  late ContentModeCubit modeCubit;
  late _FakeRepo repo;
  late _FakeSourceHealthStore health;
  late SearchBloc bloc;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('search_failure_test');
    Hive.init(tempDir.path);

    activeSource = ActiveSourceCubit();
    modeCubit = await ContentModeCubit.create(activeSource);
    health = _FakeSourceHealthStore();
    sl.registerSingleton<ContentModeCubit>(modeCubit);
    sl.registerSingleton<SearchSourcePrefs>(_FakeSearchSourcePrefs());
    sl.registerSingleton<SourceHealthStore>(health);

    repo = _FakeRepo()
      ..loadedSourcesSeed = const [
        (id: 'ani:good', name: 'Good'),
        (id: 'ani:blocked', name: 'Blocked'),
      ];

    bloc = SearchBloc(
      repo: repo,
      history: _FakeSearchHistory(),
      prefs: _FakeSearchPrefs(),
      suggestions: _FakeSuggestions(),
    );
  });

  tearDown(() async {
    await bloc.close();
    await modeCubit.close();
    await activeSource.close();
    await sl.reset();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('per-source failure reasons', () {
    test('a failing source is named with WHY, not silently dropped', () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      repo.resultFor['ani:blocked'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.blocked,
      );

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        bloc.state.failedSources,
        {'ani:blocked': SourceOutcome.blocked},
        reason:
            'the reason has to survive the fan-out — collapsing it to a bool '
            'is what left the UI with nothing to say',
      );
      // The working source is unaffected.
      expect(bloc.state.status, SearchStatus.success);
      expect(bloc.state.groups.single.sourceId, 'ani:good');
    });

    test('empty-without-error is NOT a failure', () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      repo.resultFor['ani:blocked'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.empty,
      );

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state.failedSources, isEmpty);
    });

    test('every source failing is the error state, carrying each reason',
        () async {
      repo.resultFor['ani:good'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.timeout,
      );
      repo.resultFor['ani:blocked'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.blocked,
      );

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state.status, SearchStatus.error);
      expect(bloc.state.failedSources, {
        'ani:good': SourceOutcome.timeout,
        'ani:blocked': SourceOutcome.blocked,
      });
    });

    test('a new run clears the previous run failures', () async {
      repo.resultFor['ani:blocked'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.blocked,
      );
      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(bloc.state.failedSources, isNotEmpty);

      repo.resultFor['ani:blocked'] = (
        items: [_item('ani:blocked')],
        outcome: SourceOutcome.ok,
      );
      bloc.add(const SearchRunRequested('bleach'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state.failedSources, isEmpty);
    });
  });

  group('retry', () {
    test('retrying one source unskips it and splices the results in', () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      repo.resultFor['ani:blocked'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.error,
      );

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(bloc.state.failedSources.keys, ['ani:blocked']);
      // The hard error marked it dead — which is what would make a naive
      // retry skip the very source being retried.
      expect(health.isSkippable('ani:blocked'), isTrue);

      repo.resultFor['ani:blocked'] = (
        items: [_item('ani:blocked')],
        outcome: SourceOutcome.ok,
      );
      bloc.add(const SearchRetryRequested('ani:blocked'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(health.cleared, contains('ani:blocked'));
      expect(bloc.state.failedSources, isEmpty);
      expect(
        bloc.state.groups.map((g) => g.sourceId).toSet(),
        {'ani:good', 'ani:blocked'},
        reason: 'the source that already worked must keep its results',
      );
    });

    test('a retry that fails again keeps the reason', () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      repo.resultFor['ani:blocked'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.timeout,
      );

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      bloc.add(const SearchRetryRequested('ani:blocked'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state.failedSources, {'ani:blocked': SourceOutcome.timeout});
      expect(bloc.state.status, SearchStatus.success); // good source still shows
    });

    // The case where the health skip actually bites. One source answers (with
    // nothing) so it stays alive; the other errors and is marked dead. On the
    // retry _runSearch's "drop skippable sources" filter finds a non-empty live
    // set — so it applies, and the dead source, the only one there was anything
    // to retry, is the one dropped. Clearing the mark first is what stops the
    // Retry button being a no-op. (With EVERY source dead the filter would bail
    // out and retry them all anyway, which is why that shape proves nothing.)
    test('retry-all requeries a dead source the skip would have dropped',
        () async {
      repo.resultFor['ani:good'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.empty, // answered, alive, no results
      );
      repo.resultFor['ani:blocked'] = (
        items: const <MediaItem>[],
        outcome: SourceOutcome.error, // marked dead
      );

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(bloc.state.status, SearchStatus.error);
      expect(health.isSkippable('ani:blocked'), isTrue);
      expect(health.isSkippable('ani:good'), isFalse);

      repo.resultFor['ani:blocked'] = (
        items: [_item('ani:blocked')],
        outcome: SourceOutcome.ok,
      );
      repo.searchedSourceIds.clear();

      bloc.add(const SearchRetryRequested());
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        repo.searchedSourceIds,
        contains('ani:blocked'),
        reason: 'the dead source is the whole point of the retry',
      );
      expect(bloc.state.status, SearchStatus.success);
      expect(bloc.state.failedSources, isEmpty);
      expect(bloc.state.groups.single.sourceId, 'ani:blocked');
    });
  });

  group('health-skipped sources', () {
    // The endless skeleton. The screen worked out its "still searching"
    // sections from the enabled-source list, but the bloc drops fresh-dead
    // sources before querying them — so such a source never responded, and no
    // request existed for the per-source timeout to cap. Its shimmer stayed on
    // screen for the life of the search.
    test('a skipped source is never queried and never left pending', () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      health.dead.add('ani:blocked');

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        repo.searchedSourceIds,
        isNot(contains('ani:blocked')),
        reason: 'the health check drops it before the fan-out',
      );
      expect(
        bloc.state.queriedSources,
        {'ani:good'},
        reason:
            'pending is queried − responded, so a source that was never '
            'queried can never render a skeleton',
      );
    });

    test('a skipped source is reported, not silently dropped', () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      health.dead.add('ani:blocked');

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state.failedSources, {'ani:blocked': SourceOutcome.error});
    });

    test('retrying a skipped source clears the mark and queries it', () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      repo.resultFor['ani:blocked'] = (
        items: [_item('ani:blocked')],
        outcome: SourceOutcome.ok,
      );
      health.dead.add('ani:blocked');

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      repo.searchedSourceIds.clear();

      bloc.add(const SearchRetryRequested('ani:blocked'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(repo.searchedSourceIds, contains('ani:blocked'));
      expect(bloc.state.failedSources, isEmpty);
      expect(
        bloc.state.groups.map((g) => g.sourceId).toSet(),
        {'ani:good', 'ani:blocked'},
      );
    });

    test('every source dead still queries them all (no empty search)',
        () async {
      repo.resultFor['ani:good'] = (
        items: [_item('ani:good')],
        outcome: SourceOutcome.ok,
      );
      repo.resultFor['ani:blocked'] = (
        items: [_item('ani:blocked')],
        outcome: SourceOutcome.ok,
      );
      health.dead.addAll(['ani:good', 'ani:blocked']);

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state.queriedSources, {'ani:good', 'ani:blocked'});
      expect(
        bloc.state.failedSources,
        isEmpty,
        reason: 'none were skipped, so none should be reported as skipped',
      );
    });
  });

  group('no sources', () {
    test('nothing switched on says so instead of "search failed"', () async {
      repo.loadedSourcesSeed = const [];

      bloc.add(const SearchRunRequested('naruto'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state.status, SearchStatus.error);
      expect(bloc.state.error, isNotNull);
      expect(bloc.state.failedSources, isEmpty);
    });
  });
}
