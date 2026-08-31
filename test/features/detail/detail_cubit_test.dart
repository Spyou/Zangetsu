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
    return null;
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
