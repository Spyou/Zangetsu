import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/home_catalogue_prefs.dart';
import 'package:watch_app/features/home/metadata_switch_sheet.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _manifest = {
  'id': 'org.test.addon',
  'version': '1.0.0',
  'name': 'Test Addon',
  'resources': ['catalog', 'stream'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
  'catalogs': [
    {'type': 'movie', 'id': 'top', 'name': 'Top'},
  ],
};

class _FakeSecrets implements StremioSecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _TestContentModeCubit extends Cubit<ContentMode>
    implements ContentModeCubit {
  _TestContentModeCubit() : super(ContentMode.manga);

  @override
  Future<void> setMode(ContentMode mode) async => emit(mode);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stremio_catalogue_test');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('HomeCataloguePrefs', () {
    late Box box;

    setUp(() async {
      box = await Hive.openBox('app_prefs');
      await box.clear();
      HomeCataloguePrefs.revision.value = 0;
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('app_prefs');
      await Hive.deleteBoxFromDisk(StremioManager.boxName);
      sl.reset();
    });

    test('keeps the old metadata and source values', () async {
      await box.put('homeCatalogueMode', 'metadata');
      expect(HomeCataloguePrefs.catalogueKind, HomeCatalogueKind.metadata);
      expect(HomeCataloguePrefs.catalogueShown, isFalse);
      expect(HomeCataloguePrefs.stremioSelected, isFalse);

      await box.put('homeCatalogueMode', 'source');
      expect(HomeCataloguePrefs.catalogueKind, HomeCatalogueKind.source);
      expect(HomeCataloguePrefs.sourceSelected, isTrue);
      expect(HomeCataloguePrefs.stremioSelected, isFalse);
      expect(HomeCataloguePrefs.catalogueShown, isTrue);
    });

    test('Stremio is a distinct catalogue, not a source', () async {
      await HomeCataloguePrefs.setCatalogue(
        ContentMode.anime,
        HomeCatalogueKind.stremio,
      );

      expect(HomeCataloguePrefs.catalogueKind, HomeCatalogueKind.stremio);
      expect(HomeCataloguePrefs.stremioSelected, isTrue);
      expect(HomeCataloguePrefs.sourceSelected, isFalse);
      expect(HomeCataloguePrefs.catalogueShown, isTrue);
      expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), 'stremio');
    });

    test(
      'Stremio overrides reading mode without erasing its source choice',
      () async {
        await HomeCataloguePrefs.setSourceIdFor(ContentMode.manga, 'mihan-a');
        await HomeCataloguePrefs.setCatalogue(
          ContentMode.anime,
          HomeCatalogueKind.stremio,
        );

        expect(HomeCataloguePrefs.sourceIdFor(ContentMode.manga), 'stremio');
        expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), 'stremio');
        await HomeCataloguePrefs.setCatalogue(
          ContentMode.manga,
          HomeCatalogueKind.source,
        );
        expect(HomeCataloguePrefs.sourceIdFor(ContentMode.manga), 'mihan-a');
      },
    );

    test('switching back does not erase saved source ids', () async {
      await HomeCataloguePrefs.setSourceIdFor(ContentMode.anime, 'source-a');
      await HomeCataloguePrefs.setCatalogue(
        ContentMode.anime,
        HomeCatalogueKind.stremio,
      );
      await HomeCataloguePrefs.setCatalogue(
        ContentMode.anime,
        HomeCatalogueKind.metadata,
      );

      expect(HomeCataloguePrefs.catalogueShown, isFalse);
      expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), 'source-a');
    });

    test('picking another source leaves Stremio mode explicitly', () async {
      await HomeCataloguePrefs.setCatalogue(
        ContentMode.anime,
        HomeCatalogueKind.stremio,
      );
      await HomeCataloguePrefs.setSourceIdFor(ContentMode.anime, 'source-a');

      expect(HomeCataloguePrefs.catalogueKind, HomeCatalogueKind.source);
      expect(HomeCataloguePrefs.stremioSelected, isFalse);
      expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), 'source-a');
    });

    test('every write bumps the revision', () async {
      final before = HomeCataloguePrefs.revision.value;
      await HomeCataloguePrefs.setCatalogue(
        ContentMode.anime,
        HomeCatalogueKind.source,
      );
      expect(HomeCataloguePrefs.revision.value, before + 1);
      await HomeCataloguePrefs.setSourceIdFor(ContentMode.anime, 'source-a');
      expect(HomeCataloguePrefs.revision.value, before + 2);
    });
  });

  group('metadata sheet', () {
    setUp(() async {
      final manager = StremioManager(
        client: StremioClient(
          httpClient: MockClient(
            (request) async =>
                http.Response.bytes(utf8.encode(jsonEncode(_manifest)), 200),
          ),
        ),
        secrets: _FakeSecrets(),
      );
      await manager.install('https://addon.example/addon');
      sl.registerSingleton<StremioManager>(manager);

      await ZModePrefs.init();
      final activeSource = ActiveSourceCubit(fallback: 'source-a');
      final contentMode = await ContentModeCubit.create(activeSource);
      sl.registerSingleton<ActiveSourceCubit>(activeSource);
      sl.registerSingleton<ContentModeCubit>(contentMode);
      sl.registerSingleton<MetadataProviderPrefs>(
        await MetadataProviderPrefs.open(),
      );
    });

    tearDown(() async {
      await sl.reset();
      await Hive.close();
    });

    testWidgets('offers Stremio even before any addons are installed', (
      tester,
    ) async {
      final manager = sl<StremioManager>();
      await sl.unregister<ContentModeCubit>();
      final mode = _TestContentModeCubit();
      sl.registerSingleton<ContentModeCubit>(mode);
      addTearDown(mode.close);
      await tester.runAsync(() async {
        for (final item in manager.installations) {
          await manager.remove(item.id);
        }
      });
      HomeCatalogueSelection? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selection = await showMetadataSwitchSheet(context);
                },
                child: const Text('Choose catalogue'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Choose catalogue'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Stremio'));
      await tester.tap(find.text('Stremio'));
      await tester.pumpAndSettle();

      expect(selection, HomeCatalogueSelection.stremio);
      expect(sl<ContentModeCubit>().state, ContentMode.anime);
    });
  });
}
