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
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async => _detail;
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
  ) async => (cast: <CastMember>[], relations: <MediaRelation>[]);
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
}
