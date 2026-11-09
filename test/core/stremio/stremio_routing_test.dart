import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_provider.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _manifest = {
  'id': 'org.test.addon',
  'version': '1.0.0',
  'name': 'Test Addon',
  'resources': ['catalog', 'meta', 'stream'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
  'catalogs': [
    {
      'type': 'movie',
      'id': 'top',
      'name': 'Top Movies',
      'extra': [
        {'name': 'search'},
        {'name': 'skip'},
      ],
    },
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

class _Server {
  final requests = <Uri>[];

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    final path = request.url.path;
    if (path.endsWith('/manifest.json')) {
      return _json(_manifest);
    }
    if (path.contains('/catalog/')) {
      return _json({
        'metas': [
          {'id': 'tt0372784', 'type': 'movie', 'name': 'Batman Begins'},
        ],
      });
    }
    return _json({'streams': []});
  }

  http.Response _json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _Server server;
  late StremioManager manager;
  late SourceRepository repo;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stremio_routing_test');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    if (Hive.isBoxOpen(StremioManager.boxName)) {
      await Hive.box<Map>(StremioManager.boxName).close();
    }
    await Hive.deleteBoxFromDisk(StremioManager.boxName);
    await sl.reset();
    server = _Server();
    manager = StremioManager(
      client: StremioClient(httpClient: MockClient(server.handle)),
      secrets: _FakeSecrets(),
      clock: () => DateTime(2026, 1, 1),
    );
    await manager.install('https://addon.example/addon');
    sl.registerSingleton<StremioManager>(manager);
    sl.registerSingleton<StremioProvider>(StremioProvider(manager));

    repo = SourceRepository(
      manager: ProviderManager(dio: Dio()),
      csManager: CloudStreamManager(),
      aniManager: AniyomiManager(),
      activeSource: ActiveSourceCubit(),
      prefs: PlaybackPrefs(),
    );
  });

  tearDown(() => sl.reset());

  test('Stremio appears as a source only when addons are enabled', () async {
    final sources = repo.loadedSources;
    expect(sources.map((s) => s.id), contains('stremio'));
    expect(sources.firstWhere((s) => s.id == 'stremio').name, 'Stremio');
    expect(repo.hasSource('stremio'), isTrue);
    expect(repo.displayName('stremio'), 'Stremio');
    expect(await repo.ensureSourceLoaded('stremio'), isTrue);

    await manager.setEnabled(manager.installations.single.id, false);
    expect(repo.loadedSources.map((s) => s.id), isNot(contains('stremio')));
    expect(repo.hasSource('stremio'), isFalse);
  });

  test('search routes to the Stremio provider', () async {
    final items = await repo.search('batman', sourceId: 'stremio');
    expect(items.single.id, 'movie:tt0372784');
    expect(items.single.sourceId, 'stremio');
    expect(items.single.url, startsWith('stremio://ref?'));
  });

  test('browse-more Stremio handles fetch the next raw page', () async {
    final installation = manager.installations.single;
    final more = BrowseMore(
      sourceId: 'stremio',
      kind: 'stremio_catalog',
      categoryId: jsonEncode({'i': installation.id, 't': 'movie', 'c': 'top'}),
    );

    final items = await repo.browseMore(more, 2);
    expect(items.single.id, 'movie:tt0372784');
    final catalog = server.requests.lastWhere(
      (u) => u.path.contains('/catalog/'),
    );
    expect(catalog.path, contains('skip=100'));
  });

  test('browse-more keeps unknown kinds returning empty', () async {
    final items = await repo.browseMore(
      const BrowseMore(sourceId: 'stremio', kind: 'totally_unknown'),
      1,
    );
    expect(items, isEmpty);
  });
}
