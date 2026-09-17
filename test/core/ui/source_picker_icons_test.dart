import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/hive/source_icon_store.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

// Task: source icons in the picker. `_SourceRow` (source_switcher.dart) is
// private, so these drive it the same way source_picker_test.dart does — via
// the real SourceSwitcher sheet — rather than constructing it directly.

class _FakeManager implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  Future<void> load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) async {}
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}
  @override
  void remove(String id) {}
}

class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async =>
      CachedProvider(name: name, jsCode: '', url: url, fetchedAt: DateTime.now());
  @override
  Future<void> remove(String name) async {}
}

const _metaNoIcon = LnReaderPluginMeta(
  id: 'plugin-no-icon',
  name: 'No Icon Source',
  site: 'https://a.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/a.js',
  iconUrl: '',
);

const _metaWithIcon = LnReaderPluginMeta(
  id: 'plugin-icon',
  name: 'Icon Source',
  site: 'https://b.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/b.js',
  iconUrl: 'https://cdn.test/b.png',
);

void main() {
  group('picker row icons — LNReader (novel mode)', () {
    late Directory tempDir;
    late ActiveSourceCubit activeSource;
    late ContentModeCubit modeCubit;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('source_picker_icons_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      sl.registerSingleton<AniyomiManager>(AniyomiManager());
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));

      activeSource = ActiveSourceCubit();
      modeCubit = await ContentModeCubit.create(activeSource);
      await modeCubit.setMode(ContentMode.novel);
      sl.registerSingleton<ActiveSourceCubit>(activeSource);
      sl.registerSingleton<ContentModeCubit>(modeCubit);
    });

    tearDown(() async {
      await modeCubit.close();
      await activeSource.close();
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    /// Installs [meta] straight into the LNReader box (no network) and
    /// registers a real LnReaderManager over it, then opens the picker.
    Future<void> pumpWithPlugin(WidgetTester tester, LnReaderPluginMeta meta) async {
      await tester.runAsync(() async {
        final service = LnReaderExtensionService(
          httpGet: (url) async => throw StateError('unexpected httpGet($url)'),
        );
        final manager = LnReaderManager(
          service: service,
          fetch: (url, init) async => throw StateError('fetch should not be called'),
        );
        await manager.init();
        await Hive.box<Map>(LnReaderExtensionService.boxName)
            .put(meta.id, {...meta.toMap(), 'js': ''});
        sl.registerSingleton<LnReaderManager>(manager);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => SourceSwitcher(
                currentId: 'lnr:${meta.id}',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(SourceSwitcher));
      await tester.pumpAndSettle();
    }

    testWidgets('a row with no icon shows the letter tile', (tester) async {
      await pumpWithPlugin(tester, _metaNoIcon);

      expect(find.byType(CachedNetworkImage), findsNothing);
      // "LNReader · No Icon Source" -> ecosystem tag stripped -> "N".
      expect(find.text('N'), findsOneWidget);
    });

    testWidgets(
      'a row with an icon URL builds CachedNetworkImage for it, not just the letter',
      (tester) async {
        await pumpWithPlugin(tester, _metaWithIcon);

        expect(find.byType(CachedNetworkImage), findsOneWidget);
        final img = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        expect(img.imageUrl, 'https://cdn.test/b.png');
      },
    );

    testWidgets(
      'an icon that fails to load falls back to the letter tile',
      (tester) async {
        await pumpWithPlugin(tester, _metaWithIcon);

        final img = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        // Drive the failure path directly — pump()-ing a real failed fetch
        // needs a reachable network in this sandbox; the widget's own
        // errorWidget builder IS the fallback, so calling it is the fallback.
        final fallback = img.errorWidget!(
          tester.element(find.byType(CachedNetworkImage)),
          img.imageUrl,
          Exception('network down'),
        );
        // Centred AND plated, not a bare Text: CachedNetworkImage hands its
        // errorWidget a plain 30x30 box that aligns top-left and paints
        // nothing, so an uncentred letter drew in the CORNER of the tile —
        // and since the row stopped plating tiles that have an icon url, the
        // letter has to bring its own background or a 404 leaves a bare glyph.
        expect(fallback, isA<Container>());
        final plate = fallback as Container;
        expect(plate.alignment, Alignment.center);
        expect(plate.decoration, isNotNull);
        final letter = plate.child;
        expect(letter, isA<Text>());
        expect((letter as Text).data, 'I'); // "Icon Source" -> "I"
      },
    );
  });

  group('categorizedSources: CloudStream icon from the repo catalog', () {
    late Directory tempDir;
    late CloudStreamManager mgr;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cs_icon_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      mgr = CloudStreamManager();
      sl.registerSingleton<CloudStreamManager>(mgr);
      sl.registerSingleton<AniyomiManager>(AniyomiManager());

      // One repo, two catalog entries — only one advertises an icon.
      await Hive.box(CloudStreamManager.boxName).put('repos', [
        {
          'url': 'https://repo.test/index.json',
          'name': 'Test CS Repo',
          'files': <String>[],
          'catalog': [
            {
              'internalName': 'icon-plugin',
              'name': 'Icon Plugin',
              'url': 'https://repo.test/icon.cs3',
              'version': 1,
              'iconUrl': 'https://icons.test/icon-plugin.png',
            },
            {
              'internalName': 'no-icon-plugin',
              'name': 'No Icon Plugin',
              'url': 'https://repo.test/noicon.cs3',
              'version': 1,
            },
          ],
        },
      ]);

      await mgr.loadInstalled(); // reads the persisted repo above; no channel off-Android
      mgr.rebuildFromForTest([
        {
          'name': 'Icon Plugin',
          'lang': 'en',
          'types': ['Anime'],
          'sourcePlugin': 'icon-plugin@1',
        },
        {
          'name': 'No Icon Plugin',
          'lang': 'en',
          'types': ['Anime'],
          'sourcePlugin': 'no-icon-plugin@1',
        },
      ]);
    });

    tearDown(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('a plugin the catalog has an iconUrl for gets that icon on its row', () {
      final b = categorizedSources();
      final row = b.anime.firstWhere((r) => r.id == 'cs:Icon Plugin');
      expect(row.icon, 'https://icons.test/icon-plugin.png');
    });

    test('a plugin the catalog has no iconUrl for gets a null icon', () {
      final b = categorizedSources();
      final row = b.anime.firstWhere((r) => r.id == 'cs:No Icon Plugin');
      expect(row.icon, isNull);
    });
  });

  group('categorizedSources: Aniyomi + Mihon icons from the repo index', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ani_mihon_icon_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();
      await Hive.openBox<String>(SourceIconStore.boxName);

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      sl.registerSingleton<AniyomiManager>(
        AniyomiManager()
          ..register(AniyomiProvider(
            info: const AniyomiSourceInfo(
              id: 1,
              name: 'HiAnime',
              lang: 'en',
              baseUrl: 'https://a.test',
              pkg: 'com.test.anime',
              nsfw: false,
            ),
          ))
          ..register(AniyomiProvider(
            info: const AniyomiSourceInfo(
              id: 2,
              name: 'Unseen',
              lang: 'en',
              baseUrl: 'https://b.test',
              pkg: 'com.test.unseen',
              nsfw: false,
            ),
          )),
      );
      sl.registerSingleton<MihonManager>(
        MihonManager()
          ..register(MihonProvider(
            info: const MihonSourceInfo(
              id: 42,
              name: 'MangaDex',
              lang: 'en',
              baseUrl: 'https://md.test',
              pkg: 'com.test.manga',
              nsfw: false,
            ),
          )),
      );

      // What a repo-index fetch would have left behind.
      final box = Hive.box<String>(SourceIconStore.boxName);
      await box.put('com.test.anime', 'https://icons.test/anime.png');
      await box.put('com.test.manga', 'https://icons.test/manga.png');
    });

    tearDown(() async {
      await sl.reset();
      await Hive.deleteFromDisk();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('an Aniyomi row gets the icon its repo index advertised', () {
      final row = categorizedSources().anime.firstWhere((r) => r.id == 'ani:1');
      expect(row.icon, 'https://icons.test/anime.png');
    });

    test('a Mihon row gets the icon its repo index advertised', () {
      final row = categorizedSources().manga.firstWhere((r) => r.id == 'mihon:42');
      expect(row.icon, 'https://icons.test/manga.png');
    });

    test('a package no index has been read for keeps a null icon (letter tile)', () {
      final row = categorizedSources().anime.firstWhere((r) => r.id == 'ani:2');
      expect(row.icon, isNull);
    });
  });
}
