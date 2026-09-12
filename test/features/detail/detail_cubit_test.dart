import 'dart:async';
// Final whole-branch review, Finding 3: `_enrich`'s TMDB-fallback gate used
// `d.type != ProviderType.anime`, which — once Task 1 added manga/novel to
// ProviderType — silently let id-less manga/novel details through into
// MetadataEnrichment.resolveTmdbId(). Many manga share their anime
// adaptation's title, so it often resolves and the manga ends up displaying
// the ANIME's Cast/Relations. The fix restricts the branch to
// `d.type == ProviderType.movie` (the only type that gate was ever meant to
// cover — ProviderType had just {anime, movie} before this branch).
//
// These tests exercise `_enrich` (private) via the public `DetailCubit.load()`
// entry point, with a fake MetadataEnrichment recording every call.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/metadata/episode_metadata_service.dart';
import 'package:watch_app/core/metadata/metadata_enrichment.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_extras.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';

/// Hands back a pre-built [MediaDetail] synchronously; nothing else is
/// touched by these tests. Mirrors reading_detail_routing_test.dart's
/// `_StubSourceRepository`.
class _StubSourceRepository implements SourceRepository {
  _StubSourceRepository(this._detail);
  final MediaDetail _detail;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
  }) async => _detail;
}

/// Hands back [first] on the opening fetch and [second] on every later one —
/// what a match change looks like to the cubit: same url, different source
/// behind it, so a whole new episode list arrives.
class _SwappingRepository implements SourceRepository {
  _SwappingRepository(this.first, this.second);
  final MediaDetail first;
  final MediaDetail second;
  int calls = 0;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<void> clearHttpCache() async {}

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
  }) async {
    calls++;
    return calls == 1 ? first : second;
  }
}

class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;

  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

/// Records every call instead of hitting the network. Every method returns
/// a miss (null / empty) — these tests only care WHETHER a call happened,
/// not what it resolves to.
class _FakeMetadataEnrichment extends MetadataEnrichment {
  _FakeMetadataEnrichment() : super(Dio());

  int resolveTmdbIdCalls = 0;
  int resolveMalIdCalls = 0;

  /// Non-null to exercise the id-patch path.
  int? malIdToReturn;

  /// The details `fetch()` was asked to enrich, so a test can assert both THAT
  /// it ran and what type it ran for.
  final List<ProviderType> fetchedTypes = [];

  @override
  Future<int?> resolveTmdbId(String title, String? year, bool isTv) async {
    resolveTmdbIdCalls++;
    return null;
  }

  @override
  Future<int?> resolveMalId(MediaDetail d) async {
    resolveMalIdCalls++;
    return malIdToReturn;
  }

  @override
  Future<int?> promoteMovieToAnimeMalId(MediaDetail d) async => null;

  @override
  Future<({List<CastMember> cast, List<MediaRelation> relations})> fetch(
    MediaDetail d,
  ) async {
    fetchedTypes.add(d.type);
    return (cast: <CastMember>[], relations: <MediaRelation>[]);
  }
}

MediaDetail _idLessDetail(ProviderType type) => MediaDetail(
  id: 't1',
  title: 'Some Title',
  url: 'http://test/t1',
  type: type,
  sourceId: 'test',
);

/// Emits a catalogue partial immediately, then waits on [gate] before handing
/// back the source's detail — the real shape of a Z Mode load, where the
/// source match and its episode list arrive well after the metadata.
class _PartialThenSourceRepository implements SourceRepository {
  _PartialThenSourceRepository({required this.partial, required this.finalDetail});
  final MediaDetail partial;
  final MediaDetail finalDetail;
  final gate = Completer<void>();

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
  }) async {
    onPartial?.call(partial);
    await gate.future;
    return finalDetail;
  }
}

/// Records when `fetch()` ran, and can be held open so a test can look at the
/// world while enrichment is mid-flight.
class _GatedEnrichment extends MetadataEnrichment {
  _GatedEnrichment() : super(Dio());

  int fetchCalls = 0;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<int?> resolveTmdbId(String t, String? y, bool isTv) async => null;
  @override
  Future<int?> resolveMalId(MediaDetail d) async => null;
  @override
  Future<int?> promoteMovieToAnimeMalId(MediaDetail d) async => null;

  @override
  Future<({List<CastMember> cast, List<MediaRelation> relations})> fetch(
    MediaDetail d,
  ) async {
    fetchCalls++;
    if (!started.isCompleted) started.complete();
    await release.future;
    return (
      cast: const <CastMember>[CastMember(name: 'Someone')],
      relations: const <MediaRelation>[],
    );
  }
}

Episode _ep(String id) => Episode(id: id, title: id, url: 'http://x/$id');

/// Returns the same episodes with a description added — a new list, so the
/// cubit sees it as changed, which is what makes it try to write it back.
class _FakeEpisodeMeta extends EpisodeMetadataService {
  _FakeEpisodeMeta() : super(Dio());

  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<Episode>> enrich({
    required List<Episode> episodes,
    required ProviderType type,
    int? malId,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return [for (final e in episodes) e.copyWith(description: 'desc ${e.id}')];
  }
}

void main() {
  late _FakeMetadataEnrichment fakeEnrichment;

  setUp(() async {
    await sl.reset();
    fakeEnrichment = _FakeMetadataEnrichment();
    sl.registerSingleton<MetadataEnrichment>(fakeEnrichment);
  });

  tearDown(() async {
    await sl.reset();
  });

  Future<DetailCubit> loadCubit(MediaDetail detail) async {
    final cubit = DetailCubit(
      repo: _StubSourceRepository(detail),
      url: detail.url,
      prefs: _FakeTitlePrefs(),
    );
    await cubit.load();
    // _enrich() is fire-and-forget from load() — let its awaits flush.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return cubit;
  }

  group('Cast and Relations do not queue behind the episode list', () {
    // They run off malId/tmdbId/title, all of which arrive with the catalogue
    // partial. Waiting for the source match meant they landed a beat after the
    // episodes every time, for no reason.
    late _GatedEnrichment gated;
    late _FakeEpisodeMeta epMeta;
    late _PartialThenSourceRepository repo;
    late DetailCubit cubit;

    setUp(() async {
      await sl.reset();
      gated = _GatedEnrichment();
      sl.registerSingleton<MetadataEnrichment>(gated);
      // Registered so the per-episode description step actually runs — that is
      // the one enrichment result tied to a SPECIFIC episode list, and so the
      // one that can push the catalogue's list back over the source's.
      epMeta = _FakeEpisodeMeta();
      sl.registerSingleton<EpisodeMetadataService>(epMeta);
      const base = MediaDetail(
        id: 't1',
        title: 'Some Title',
        url: 'http://test/t1',
        type: ProviderType.anime,
        sourceId: 'test',
        malId: 5114,
      );
      repo = _PartialThenSourceRepository(
        partial: base.copyWith(episodes: [_ep('cat1'), _ep('cat2')]),
        finalDetail: base.copyWith(episodes: [_ep('src1')]),
      );
      cubit = DetailCubit(
        repo: repo,
        url: base.url,
        prefs: _FakeTitlePrefs(),
      );
    });

    tearDown(() async => cubit.close());

    test('enrichment starts before the source episodes arrive', () async {
      final loading = cubit.load();
      await epMeta.started.future; // would hang if it waited for the gate below

      expect(repo.gate.isCompleted, isFalse, reason: 'source still fetching');

      epMeta.release.complete();
      repo.gate.complete();
      gated.release.complete();
      await loading;
      expect(gated.fetchCalls, 1);
    });

    test('it runs once, not once per entry point', () async {
      final loading = cubit.load();
      await epMeta.started.future;
      epMeta.release.complete();
      repo.gate.complete();
      gated.release.complete();
      await loading;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // load() still calls _enrich after the await, for the paths that emit no
      // partial at all. That call has to JOIN this one, not start a second.
      expect(gated.fetchCalls, 1);
    });

    test('an id resolved by enrichment reaches the screen', () async {
      // The other half of patching current state: it must still APPLY the
      // change. The player and scrobbler key off this id, so losing it here
      // is silent until something fails to track.
      await sl.reset();
      final resolving = _FakeMetadataEnrichment()..malIdToReturn = 1735;
      sl.registerSingleton<MetadataEnrichment>(resolving);
      final c = DetailCubit(
        repo: _StubSourceRepository(_idLessDetail(ProviderType.anime)),
        url: 'http://test/t1',
        prefs: _FakeTitlePrefs(),
      );
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.state.detail!.malId, 1735);
      await c.close();
    });

    test('a late enrichment does not put the catalogue episodes back',
        () async {
      // Enrichment holds the detail it started from — the partial, whose
      // episodes are the catalogue's. Emitting that copy after the source list
      // landed would make the list fill in and then visibly revert.
      // Hold the per-episode step open until AFTER the source list has landed,
      // so what it finishes with belongs to the list it no longer has.
      final loading = cubit.load();
      await epMeta.started.future;
      repo.gate.complete();
      await loading;
      expect(cubit.state.detail!.episodes.map((e) => e.id), ['src1']);

      epMeta.release.complete();
      gated.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        cubit.state.detail!.episodes.map((e) => e.id),
        ['src1'],
        reason: 'the catalogue list came back after the source list',
      );
      expect(cubit.state.cast, isNotEmpty, reason: 'and it still enriched');
    });
  });

  test(
    'an id-less MANGA detail never triggers TMDB resolution',
    () async {
      await loadCubit(_idLessDetail(ProviderType.manga));
      expect(fakeEnrichment.resolveTmdbIdCalls, 0);
    },
  );

  test(
    'an id-less NOVEL detail never triggers TMDB resolution',
    () async {
      await loadCubit(_idLessDetail(ProviderType.novel));
      expect(fakeEnrichment.resolveTmdbIdCalls, 0);
    },
  );

  test(
    'an id-less MOVIE detail still triggers TMDB resolution (unchanged)',
    () async {
      await loadCubit(_idLessDetail(ProviderType.movie));
      expect(fakeEnrichment.resolveTmdbIdCalls, 1);
    },
  );

  test(
    'an id-less ANIME detail never triggers TMDB resolution (unchanged — '
    'gated out both before and after this fix) and instead resolves via '
    'the anime-specific MAL-id path',
    () async {
      await loadCubit(_idLessDetail(ProviderType.anime));
      expect(fakeEnrichment.resolveTmdbIdCalls, 0);
      expect(fakeEnrichment.resolveMalIdCalls, 1);
    },
  );

  // Cast/Relations for reading titles. The enrichment gate wanted a malId, a
  // tmdbId, or anime — a Mihon manga has none of the three, so the tabs stayed
  // empty. Manga/novel now go through fetch(), which routes them to AniList's
  // MANGA side; the TMDB path above stays shut, which is what keeps an anime
  // adaptation's cast off a manga page.
  group('reading titles reach Cast/Relations', () {
    test('an id-less MANGA detail is enriched', () async {
      await loadCubit(_idLessDetail(ProviderType.manga));
      expect(fakeEnrichment.fetchedTypes, [ProviderType.manga]);
      expect(fakeEnrichment.resolveTmdbIdCalls, 0,
          reason: 'still never the video databases — that was the old bug');
      expect(fakeEnrichment.resolveMalIdCalls, 0,
          reason: 'the MAL step is the anime path, not this one');
    });

    test('an id-less NOVEL detail is enriched', () async {
      await loadCubit(_idLessDetail(ProviderType.novel));
      expect(fakeEnrichment.fetchedTypes, [ProviderType.novel]);
      expect(fakeEnrichment.resolveTmdbIdCalls, 0);
    });

    test('anime still enriches (unchanged)', () async {
      await loadCubit(_idLessDetail(ProviderType.anime));
      expect(fakeEnrichment.fetchedTypes, [ProviderType.anime]);
    });
  });

  // A match change re-fetches through refresh(). Everything _enrich produced
  // lives only on the in-memory detail, so a bare re-emit of the repo's copy
  // silently un-resolves the title and strips per-episode metadata — and
  // _enrich's own guard (Cast/Relations already present) stops it healing
  // itself. Both halves are asserted here.
  group('refresh() after a match change', () {
    // Enriched once: carries an id and has relations, so the guard is armed.
    final enriched = MediaDetail(
      id: 't1',
      title: 'Some Title',
      url: 'http://test/t1',
      type: ProviderType.anime,
      sourceId: 'test',
      malId: 42,
      relations: const [MediaRelation(title: 'Sequel')],
      episodes: const [Episode(id: '1', title: 'Ep 1', url: 'u1', number: 1)],
    );
    // What the new source returns: no id of its own, a different list.
    final swapped = MediaDetail(
      id: 't1',
      title: 'Some Title',
      url: 'http://test/t1',
      type: ProviderType.anime,
      sourceId: 'test',
      relations: const [MediaRelation(title: 'Sequel')],
      episodes: const [
        Episode(id: '1', title: 'Ep 1', url: 'v1', number: 1),
        Episode(id: '2', title: 'Ep 2', url: 'v2', number: 2),
      ],
    );

    Future<DetailCubit> loadThenRefresh() async {
      final cubit = DetailCubit(
        repo: _SwappingRepository(enriched, swapped),
        url: enriched.url,
        prefs: _FakeTitlePrefs(),
      );
      await cubit.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await cubit.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return cubit;
    }

    test('keeps an id the repo no longer supplies', () async {
      final cubit = await loadThenRefresh();
      expect(cubit.state.detail!.malId, 42,
          reason: 'a resolved id must survive the re-fetch, or the scrobbler '
              'loses the id it keys off');
      expect(cubit.state.detail!.episodes.length, 2,
          reason: 'the new list must still replace the old one');
      await cubit.close();
    });

    test('re-runs enrichment for the new episode list', () async {
      final cubit = await loadThenRefresh();
      expect(fakeEnrichment.fetchedTypes.length, 2,
          reason: 'enrichment must run again after the list is swapped; the '
              'already-enriched guard would otherwise skip it');
      await cubit.close();
    });
  });
}
