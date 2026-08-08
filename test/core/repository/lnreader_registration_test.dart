import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

/// Task 6's isolation net: proves a `lnr:` novel source is wired end-to-end
/// (type resolution, mode filtering, `SourceRepository` registration) WITHOUT
/// ever paying the QuickJS runtime cost — registration/listing only ever
/// reads stored plugin meta. Uses a fake httpGet/fetch (no real network) and
/// an in-memory Hive box, same shape as `test/core/lnreader/lnreader_manager_test.dart`.

const _metaA = LnReaderPluginMeta(
  id: 'plugin-a',
  name: 'Plugin A',
  site: 'https://a.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/a.js',
  iconUrl: 'https://cdn.test/a.png',
);

String _pluginJs() => '''
module.exports.default = {
  name: 'Plugin A', site: '${_metaA.site}', version: '1.0.0', filters: {},
  popularNovels: function (p, o) { return Promise.resolve([]); },
  searchNovels: function (t, p) { return Promise.resolve([]); },
  parseNovel: function (x) { return Promise.resolve({name: 'N', chapters: []}); },
  parseChapter: function (x) { return Promise.resolve(''); },
};
''';

void main() {
  // ProviderManager eagerly spins up the QuickJS runtime in its constructor.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LnReaderManager lnrManager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lnreader_registration_test');
    Hive.init(tempDir.path);
    await PlaybackPrefs.init();

    final service = LnReaderExtensionService(
      httpGet: (url) async {
        if (url == _metaA.url) return _pluginJs();
        throw StateError('unexpected httpGet($url)');
      },
    );
    lnrManager = LnReaderManager(
      service: service,
      fetch: (url, init) async =>
          throw StateError('fetch should not be called — installedSources/get never load the plugin'),
    );
    await lnrManager.init(); // box open only
    await service.install(_metaA);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('sourceTypeOf types an lnr: id as ProviderType.novel', () {
    expect(sourceTypeOf('lnr:plugin-a'), ProviderType.novel);
  });

  test(
    'filterSourcesForMode includes lnr: in novel mode and excludes it from '
    'anime and manga mode — the isolation proof',
    () {
      final srcs = {
        'lnr:plugin-a': sourceTypeOf('lnr:plugin-a'),
        'ani:1': sourceTypeOf('ani:1'),
        'mihon:7': sourceTypeOf('mihon:7'),
      };

      final novel = filterSourcesForMode(srcs, ContentMode.novel, (t) => t);
      expect(novel.keys, contains('lnr:plugin-a'));
      expect(novel.keys, isNot(contains('ani:1')));
      expect(novel.keys, isNot(contains('mihon:7')));

      final anime = filterSourcesForMode(srcs, ContentMode.anime, (t) => t);
      expect(anime.keys, isNot(contains('lnr:plugin-a')));
      expect(anime.keys, contains('ani:1'));

      final manga = filterSourcesForMode(srcs, ContentMode.manga, (t) => t);
      expect(manga.keys, isNot(contains('lnr:plugin-a')));
      expect(manga.keys, contains('mihon:7'));
    },
  );

  test(
    'SourceRepository.loadedSources/displayName/hasSource/baseUrlFor see the '
    'installed lnr: plugin',
    () {
      final repo = SourceRepository(
        manager: ProviderManager(dio: Dio()),
        csManager: CloudStreamManager(),
        aniManager: AniyomiManager(),
        lnrManager: lnrManager,
        activeSource: ActiveSourceCubit(),
        prefs: PlaybackPrefs(),
      );

      final ids = repo.loadedSources.map((s) => s.id).toList();
      expect(ids, contains('lnr:plugin-a'));
      expect(
        repo.loadedSources.firstWhere((s) => s.id == 'lnr:plugin-a').name,
        'Plugin A',
      );
      expect(repo.displayName('lnr:plugin-a'), 'Plugin A');
      expect(repo.hasSource('lnr:plugin-a'), isTrue);
      expect(repo.hasSource('lnr:nope'), isFalse);
      expect(repo.baseUrlFor('lnr:plugin-a'), 'https://a.test/');
    },
  );

  test('omitting lnrManager entirely leaves lnr: ids unresolvable, not a crash', () {
    final repo = SourceRepository(
      manager: ProviderManager(dio: Dio()),
      csManager: CloudStreamManager(),
      aniManager: AniyomiManager(),
      activeSource: ActiveSourceCubit(),
      prefs: PlaybackPrefs(),
    );
    expect(repo.hasSource('lnr:plugin-a'), isFalse);
    expect(repo.loadedSources.map((s) => s.id), isNot(contains('lnr:plugin-a')));
  });

  test(
    'registering/listing the lnr: source never builds the QuickJS runtime — '
    'the no-startup-cost proof',
    () {
      // Drive every registration/listing path this task wires — init(),
      // installedSources, get(), and a full SourceRepository built on top of
      // them — then assert the runtime was never built. This is the same
      // exercise the 'SourceRepository...' test above runs; repeating it here
      // right next to the runtimeBuilt assertion is what makes this test's
      // name true on its own, without relying on test execution order.
      final repo = SourceRepository(
        manager: ProviderManager(dio: Dio()),
        csManager: CloudStreamManager(),
        aniManager: AniyomiManager(),
        lnrManager: lnrManager,
        activeSource: ActiveSourceCubit(),
        prefs: PlaybackPrefs(),
      );
      expect(lnrManager.installedSources.single.id, 'lnr:plugin-a');
      expect(lnrManager.get('lnr:plugin-a'), isNotNull);
      expect(repo.loadedSources.map((s) => s.id), contains('lnr:plugin-a'));
      expect(repo.hasSource('lnr:plugin-a'), isTrue);

      expect(lnrManager.runtimeBuilt, isFalse);
    },
  );
}
