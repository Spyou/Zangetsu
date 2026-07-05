import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

/// A fake Aniyomi provider that records which paging method was called (and the
/// page it was asked for), so we can assert [SourceRepository.browseMore]'s
/// routing without any native channel.
class _RecordingAniProvider extends AniyomiProvider {
  _RecordingAniProvider(int id)
    : super(
        info: AniyomiSourceInfo(
          id: id,
          name: 'Fake $id',
          lang: 'en',
          baseUrl: '',
          pkg: 'fake',
          nsfw: false,
        ),
      );

  String? calledMethod;
  int? calledPage;

  MediaItem _sentinel(String tag) => MediaItem(
    id: tag,
    title: tag,
    url: 'https://fake.test/$tag',
    type: ProviderType.anime,
    sourceId: sourceId,
  );

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    calledMethod = 'popular';
    calledPage = page;
    return [_sentinel('popular')];
  }

  @override
  Future<List<MediaItem>> latest({int page = 1}) async {
    calledMethod = 'latest';
    calledPage = page;
    return [_sentinel('latest')];
  }
}

SourceRepository _repoWith(AniyomiManager aniManager) => SourceRepository(
  manager: ProviderManager(dio: Dio()),
  csManager: CloudStreamManager(),
  aniManager: aniManager,
  activeSource: ActiveSourceCubit(),
  prefs: PlaybackPrefs(),
);

void main() {
  // ProviderManager eagerly spins up the QuickJS runtime in its constructor;
  // that needs the Flutter test binding to be initialised first.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SourceRepository.browseMore routing', () {
    test('ani_popular routes to popular(page:)', () async {
      final ani = AniyomiManager();
      final p = _RecordingAniProvider(1);
      ani.register(p);
      final repo = _repoWith(ani);

      final res = await repo.browseMore(
        BrowseMore(sourceId: p.sourceId, kind: 'ani_popular'),
        2,
      );
      expect(p.calledMethod, 'popular');
      expect(p.calledPage, 2);
      expect(res.single.id, 'popular');
    });

    test('ani_latest routes to latest(page:)', () async {
      final ani = AniyomiManager();
      final p = _RecordingAniProvider(2);
      ani.register(p);
      final repo = _repoWith(ani);

      final res = await repo.browseMore(
        BrowseMore(sourceId: p.sourceId, kind: 'ani_latest'),
        3,
      );
      expect(p.calledMethod, 'latest');
      expect(p.calledPage, 3);
      expect(res.single.id, 'latest');
    });

    test('cs_mainpage on a non-CloudStream provider degrades to []', () async {
      final ani = AniyomiManager();
      final p = _RecordingAniProvider(3);
      ani.register(p);
      final repo = _repoWith(ani);

      // Wrong provider type for the kind → guarded to empty (never throws).
      final res = await repo.browseMore(
        BrowseMore(
          sourceId: p.sourceId,
          kind: 'cs_mainpage',
          categoryId: 'Popular data',
        ),
        2,
      );
      expect(res, isEmpty);
      expect(p.calledMethod, isNull);
    });

    test('unknown kind returns []', () async {
      final ani = AniyomiManager();
      final p = _RecordingAniProvider(4);
      ani.register(p);
      final repo = _repoWith(ani);

      final res = await repo.browseMore(
        BrowseMore(sourceId: p.sourceId, kind: 'totally_unknown'),
        2,
      );
      expect(res, isEmpty);
      expect(p.calledMethod, isNull);
    });

    test('never throws when the provider is not loaded', () async {
      final repo = _repoWith(AniyomiManager());
      // No provider registered for this id → _providerFor would throw; browseMore
      // must swallow it and return [].
      final res = await repo.browseMore(
        const BrowseMore(sourceId: 'ani:999', kind: 'ani_popular'),
        2,
      );
      expect(res, isEmpty);
    });
  });
}
