// Fix 1: a Cloudflare challenge on the Detail path was silently swallowed by
// DetailCubit's bare `catch (_)` in load()/refresh() — the "solve Cloudflare"
// prompt only ever surfaced from Home. These tests exercise the two fixed
// paths directly: the exception Mihon/Aniyomi throw, and the novel-plugin
// latch fallback (LnReaderProvider.getDetail returns an empty detail rather
// than throwing, mirroring HomeCubit's own fallback for the same reason).

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/error/exceptions.dart';
import 'package:watch_app/core/lnreader/novel_cloudflare.dart';
import 'package:watch_app/core/metadata/metadata_enrichment.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';
import 'package:dio/dio.dart';
import 'package:watch_app/core/models/media_extras.dart';

class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;

  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

/// Records every call instead of hitting the network — mirrors
/// detail_cubit_test.dart's fake so load()'s fire-and-forget `_enrich` never
/// touches DI singletons that aren't registered.
class _FakeMetadataEnrichment extends MetadataEnrichment {
  _FakeMetadataEnrichment() : super(Dio());

  @override
  Future<int?> resolveTmdbId(String title, String? year, bool isTv) async => null;

  @override
  Future<int?> resolveMalId(MediaDetail d) async => null;

  @override
  Future<int?> promoteMovieToAnimeMalId(MediaDetail d) async => null;

  @override
  Future<({List<CastMember> cast, List<MediaRelation> relations})> fetch(
    MediaDetail d,
  ) async => (cast: <CastMember>[], relations: <MediaRelation>[]);
}

/// `detail()` succeeds [succeedTimes] times (returning [ok]), then throws
/// [CloudflareRequiredException] on every call after — enough to drive both
/// load() (0 successes first) and refresh() (1 success, then the block).
class _CloudflareRepo implements SourceRepository {
  _CloudflareRepo(this.cfUrl, {this.ok, this.succeedTimes = 0});
  final String cfUrl;
  final MediaDetail? ok;
  final int succeedTimes;
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
  }) async {
    calls++;
    if (calls <= succeedTimes) return ok!;
    throw CloudflareRequiredException(cfUrl);
  }
}

/// Always succeeds with [okDetail] — the "nothing went wrong" control case.
class _NormalRepo implements SourceRepository {
  _NormalRepo(this.okDetail);
  final MediaDetail okDetail;

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
  }) async => okDetail;
}

/// `detail()` succeeds but returns an EMPTY-title detail — what a novel
/// plugin's swallowed Cloudflare fetch failure looks like on the wire
/// (LnReaderProvider.getDetail's fallback), never an exception.
class _NovelLatchRepo implements SourceRepository {
  _NovelLatchRepo(this.url);
  final String url;

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
  }) async => MediaDetail(
    id: url,
    title: '',
    url: url,
    type: ProviderType.novel,
    sourceId: 'lnr:test',
  );
}

const _cfUrl = 'https://example.test/cf';

MediaDetail _detail({String title = 'Some Title'}) => MediaDetail(
  id: 't1',
  title: title,
  url: 'http://test/t1',
  type: ProviderType.anime,
  sourceId: 'test',
);

void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<MetadataEnrichment>(_FakeMetadataEnrichment());
  });

  tearDown(() async {
    await sl.reset();
    NovelCloudflare.clear();
  });

  test('load() exposes the Cloudflare URL instead of a generic error',
      () async {
    final cubit = DetailCubit(
      repo: _CloudflareRepo(_cfUrl),
      url: 'http://test/t1',
      prefs: _FakeTitlePrefs(),
    );
    await cubit.load();
    expect(cubit.state.cloudflareUrl, _cfUrl);
    expect(cubit.state.status, DetailStatus.error);
    expect(cubit.state.error, isNull,
        reason: 'a Cloudflare block is not the generic load_failed error');
    await cubit.close();
  });

  test('refresh() exposes the Cloudflare URL instead of a generic error',
      () async {
    final cubit = DetailCubit(
      repo: _CloudflareRepo(_cfUrl, ok: _detail(), succeedTimes: 1),
      url: 'http://test/t1',
      prefs: _FakeTitlePrefs(),
    );
    await cubit.load();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cubit.state.cloudflareUrl, isNull);

    await cubit.refresh();
    expect(cubit.state.cloudflareUrl, _cfUrl);
    await cubit.close();
  });

  test('a normal load succeeds and sets no Cloudflare URL', () async {
    final cubit = DetailCubit(
      repo: _NormalRepo(_detail()),
      url: 'http://test/t1',
      prefs: _FakeTitlePrefs(),
    );
    await cubit.load();
    expect(cubit.state.status, DetailStatus.success);
    expect(cubit.state.cloudflareUrl, isNull);
    await cubit.close();
  });

  test(
    'load() picks up the novel-plugin Cloudflare latch when the detail '
    'comes back empty instead of throwing',
    () async {
      NovelCloudflare.needsSolve(_cfUrl);
      final cubit = DetailCubit(
        repo: _NovelLatchRepo('http://novel.test/t1'),
        url: 'http://novel.test/t1',
        prefs: _FakeTitlePrefs(),
      );
      await cubit.load();
      expect(cubit.state.cloudflareUrl, _cfUrl);
      await cubit.close();
    },
  );
}
