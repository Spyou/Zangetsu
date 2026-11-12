import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _manifest = {
  'id': 'org.test.addon',
  'version': '1.0.0',
  'name': 'Test Addon',
  'description': 'Test catalogue',
  'resources': ['catalog', 'meta', 'stream', 'subtitles'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
  'catalogs': [
    {
      'type': 'movie',
      'id': 'top',
      'name': 'Top',
      'extra': [
        {'name': 'search'},
        {'name': 'skip'},
      ],
    },
  ],
};

class _FakeSecrets implements StremioSecretStore {
  final Map<String, String> values = {};
  bool unavailable = false;

  @override
  Future<void> delete(String key) async {
    if (unavailable) throw StateError('no keychain');
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (unavailable) throw StateError('no keychain');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (unavailable) throw StateError('no keychain');
    values[key] = value;
  }
}

class _Server {
  int manifests = 0;
  String manifestId = 'org.test.addon';
  int streams = 0;
  int metas = 0;
  final requests = <Uri>[];
  Completer<void>? holdStreams;
  int status = 200;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    final path = request.url.path;
    if (path.endsWith('/manifest.json')) {
      manifests++;
      return _json({..._manifest, 'id': manifestId});
    }
    if (path.contains('/streams/') || path.contains('/stream/')) {
      streams++;
      if (holdStreams != null) await holdStreams!.future;
      return _json({
        'streams': [
          {'name': 'Direct', 'url': 'https://cdn.example/video.m3u8'},
        ],
      });
    }
    if (path.contains('/meta/')) {
      metas++;
      final segments = request.url.pathSegments;
      final id = segments.last.replaceAll('.json', '');
      return _json({
        'meta': {'id': id, 'type': 'movie', 'name': 'Meta $id'},
      });
    }
    return _json({'metas': []});
  }

  http.Response _json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), status);
}

void main() {
  late Directory tempDir;
  late _FakeSecrets secrets;
  late DateTime now;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stremio_manager_test');
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
    secrets = _FakeSecrets();
    now = DateTime(2026, 1, 1, 12);
  });

  StremioManager makeManager(_Server server) => StremioManager(
    client: StremioClient(httpClient: MockClient(server.handle)),
    secrets: secrets,
    clock: () => now,
  );

  test(
    'saved shared titles remain openable without their original installation',
    () async {
      final manager = makeManager(_Server());
      await manager.init();
      const shared = StremioRef(
        installationId: 'old-device',
        type: 'series',
        itemId: 'tt1',
      );
      const local = StremioRef(
        installationId: 'old-device',
        type: 'series',
        itemId: 'local:1',
      );
      expect(manager.canOpen(shared), isTrue);
      expect(manager.canOpen(local), isFalse);
      final installed = await manager.install('https://addon.example');
      final localInstalled = StremioRef(
        installationId: installed.id,
        type: 'series',
        itemId: 'local:1',
      );
      expect(
        manager.canOpen(localInstalled, revision: installed.revision),
        isTrue,
      );
      await manager.setEnabled(installed.id, false);
      expect(
        manager.canOpen(localInstalled, revision: installed.revision),
        isFalse,
      );
    },
  );

  test(
    'hidden Home catalogues persist without disabling metadata or invalidating streams',
    () async {
      final manager = makeManager(_Server());
      final installed = await manager.install('https://addon.example');
      await manager.setCatalogVisible(installed.id, 'movie', 'top', false);
      final restored = makeManager(_Server());
      await restored.init();
      final saved = restored.installations.single;
      expect(saved.isCatalogVisible('movie', 'top'), isFalse);
      expect(saved.enabled, isTrue);
      expect(saved.supports('meta'), isTrue);
      expect(saved.revision, installed.revision);
      await restored.configure(saved.id, 'https://updated.example');
      expect(
        restored.installations.single.isCatalogVisible('movie', 'top'),
        isFalse,
      );
      await restored.setCatalogVisible(saved.id, 'movie', 'top', true);
      expect(
        restored.installations.single.isCatalogVisible('movie', 'top'),
        isTrue,
      );
    },
  );

  test('addon order can move and survives restart', () async {
    final manager = makeManager(_Server());
    final first = await manager.install('https://first.example');
    final second = await manager.install('https://second.example');
    await manager.move(second.id, -1);
    expect(manager.installations.first.id, second.id);
    final restored = makeManager(_Server());
    await restored.init();
    expect(restored.installations.map((i) => i.id), [second.id, first.id]);
    await restored.move(second.id, 1);
    expect(restored.installations.first.id, first.id);
  });

  test('accepts Stremio installation links', () async {
    final manager = makeManager(_Server());
    final addon = await manager.install(
      'stremio://addon.example/manifest.json',
    );
    expect((await manager.baseUri(addon.id))!.scheme, 'https');
  });

  test('default metadata is available offline and is not duplicated', () async {
    final server = _Server();
    final manager = makeManager(server);
    await manager.init();
    await manager.ensureDefaultMetadata();
    await manager.ensureDefaultMetadata();
    expect(manager.installations.single.manifestId, 'com.linvo.cinemeta');
    expect(manager.installations.single.supports('meta'), isTrue);
    expect(manager.installations.single.catalogs, hasLength(6));
    expect(manager.installations.single.catalogs.map((c) => c.id), [
      'top',
      'top',
      'year',
      'year',
      'imdbRating',
      'imdbRating',
    ]);
    expect(server.manifests, 0);
  });

  test(
    'deleted default metadata stays removed after a storage restart',
    () async {
      final manager = makeManager(_Server());
      await manager.ensureDefaultMetadata();
      await manager.remove(StremioManager.defaultMetadataId);
      expect(manager.installations, isEmpty);
      await Hive.box<Map>(StremioManager.boxName).close();
      final restored = makeManager(_Server());
      await restored.ensureDefaultMetadata();
      await restored.ensureDefaultMetadata();
      expect(restored.installations, isEmpty);
    },
  );

  test(
    'deleting default metadata keeps other addons and allows manual reinstall',
    () async {
      final server = _Server();
      final manager = makeManager(server);
      await manager.ensureDefaultMetadata();
      final other = await manager.install('https://other.example');
      await manager.remove(StremioManager.defaultMetadataId);
      final restored = makeManager(server);
      await restored.ensureDefaultMetadata();
      expect(restored.installations.single.id, other.id);
      server.manifestId = 'com.linvo.cinemeta';
      now = now.add(const Duration(seconds: 1));
      final reinstalled = await restored.install(
        StremioManager.defaultMetadataUrl,
      );
      await restored.ensureDefaultMetadata();
      expect(restored.byId(reinstalled.id)?.enabled, isTrue);
      expect(restored.installations, hasLength(2));
    },
  );

  test(
    'removing a manually installed Cinemeta does not trigger default seeding',
    () async {
      final server = _Server()..manifestId = 'com.linvo.cinemeta';
      final manager = makeManager(server);
      final installed = await manager.install(
        StremioManager.defaultMetadataUrl,
      );
      await manager.ensureDefaultMetadata();
      expect(manager.installations.single.id, installed.id);
      await manager.remove(installed.id);
      final restored = makeManager(server);
      await restored.ensureDefaultMetadata();
      expect(restored.installations, isEmpty);
    },
  );

  test(
    'removing another addon still allows first-time default metadata',
    () async {
      final manager = makeManager(_Server());
      final installed = await manager.install('https://other.example');
      await manager.remove(installed.id);
      await manager.ensureDefaultMetadata();
      expect(manager.installations.single.id, StremioManager.defaultMetadataId);
    },
  );

  test(
    'upgrades the two-row default without enabling it or changing order',
    () async {
      final manager = makeManager(_Server());
      await manager.ensureDefaultMetadata();
      final original = manager.installations.single;
      final old = original.toJson();
      old['catalogs'] = (old['catalogs'] as List).take(2).toList();
      old['enabled'] = false;
      old['position'] = 3;
      await Hive.box<Map>(StremioManager.boxName).put(original.id, old);
      final restored = makeManager(_Server());
      await restored.ensureDefaultMetadata();
      final upgraded = restored.installations.single;
      expect(upgraded.catalogs, hasLength(6));
      expect(upgraded.enabled, isFalse);
      expect(upgraded.position, 3);
      expect(upgraded.id, original.id);
    },
  );

  test('install validates, persists and survives restart', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install(
      'https://addon.example/configured/manifest.json?token=abc',
    );

    expect(installation.name, 'Test Addon');
    expect(installation.manifestId, 'org.test.addon');
    expect(installation.catalogs.single.name, 'Top');
    expect(installation.enabled, isTrue);
    expect(secrets.values, hasLength(1));

    final restarted = makeManager(server);
    await restarted.init();
    expect(restarted.installations, hasLength(1));
    expect(restarted.installations.single.id, installation.id);
    expect(
      await restarted.baseUri(installation.id),
      Uri.parse('https://addon.example/configured?token=abc'),
    );
  });

  test('duplicate configured URL is rejected in any spelling', () async {
    final server = _Server();
    final manager = makeManager(server);
    await manager.install('https://addon.example/addon');

    await expectLater(
      manager.install('https://addon.example/addon/manifest.json'),
      throwsA(isA<StremioInstallException>()),
    );
    expect(manager.installations, hasLength(1));
  });

  test('two configurations sharing a manifest id stay independent', () async {
    final server = _Server();
    final manager = makeManager(server);
    await manager.install('https://a.example/addon');
    await manager.install('https://b.example/addon');

    final ids = manager.installations.map((i) => i.id).toSet();
    expect(ids, hasLength(2));
    expect(manager.installations.map((i) => i.manifestId).toSet(), {
      'org.test.addon',
    });

    await manager.streams(
      manager.installations.first.id,
      type: 'movie',
      itemId: 'tt1',
    );
    await manager.streams(
      manager.installations.last.id,
      type: 'movie',
      itemId: 'tt1',
    );
    expect(server.streams, 2);
    expect(server.requests.where((u) => u.host == 'a.example'), isNotEmpty);
    expect(server.requests.where((u) => u.host == 'b.example'), isNotEmpty);
  });

  test('failed secret write leaves no installation behind', () async {
    final server = _Server();
    final manager = makeManager(server);
    secrets.unavailable = true;

    await expectLater(
      manager.install('https://addon.example/addon'),
      throwsA(isA<StremioInstallException>()),
    );
    expect(manager.installations, isEmpty);

    secrets.unavailable = false;
    final restarted = makeManager(server);
    await restarted.init();
    expect(restarted.installations, isEmpty);
  });

  test('configure keeps the local id and bumps the revision', () async {
    final server = _Server();
    final manager = makeManager(server);
    final first = await manager.install('https://addon.example/addon');

    await manager.streams(first.id, type: 'movie', itemId: 'tt1');
    expect(server.streams, 1);

    final updated = await manager.configure(
      first.id,
      'https://addon.example/addon2',
    );
    expect(updated.id, first.id);
    expect(updated.revision, first.revision + 1);
    expect(
      await manager.baseUri(first.id),
      Uri.parse('https://addon.example/addon2'),
    );

    await manager.streams(first.id, type: 'movie', itemId: 'tt1');
    expect(server.streams, 2);
  });

  test('configure cannot take another installation URL', () async {
    final server = _Server();
    final manager = makeManager(server);
    final first = await manager.install('https://a.example/addon');
    await manager.install('https://b.example/addon');

    await expectLater(
      manager.configure(first.id, 'https://b.example/addon'),
      throwsA(isA<StremioInstallException>()),
    );
  });

  test('remove deletes record and secret', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/addon');

    await manager.remove(installation.id);

    expect(manager.installations, isEmpty);
    expect(secrets.values, isEmpty);
    final restarted = makeManager(server);
    await restarted.init();
    expect(restarted.installations, isEmpty);
  });

  test('enable and disable invalidate cached streams', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/addon');

    await manager.streams(installation.id, type: 'movie', itemId: 'tt1');
    await manager.streams(installation.id, type: 'movie', itemId: 'tt1');
    expect(server.streams, 1);

    await manager.setEnabled(installation.id, false);
    expect(manager.byId(installation.id)!.revision, 1);
    await manager.setEnabled(installation.id, true);
    expect(manager.byId(installation.id)!.revision, 2);

    await manager.streams(installation.id, type: 'movie', itemId: 'tt1');
    expect(server.streams, 2);
  });

  test('manifest and meta caches are bounded by ttl', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/addon');
    expect(server.manifests, 1);

    await manager.manifest(installation.id);
    await manager.manifest(installation.id);
    expect(server.manifests, 1);

    await manager.meta(installation.id, type: 'movie', itemId: 'tt1');
    await manager.meta(installation.id, type: 'movie', itemId: 'tt1');
    expect(server.metas, 1);

    now = now.add(const Duration(minutes: 6));
    await manager.meta(installation.id, type: 'movie', itemId: 'tt1');
    expect(server.metas, 2);
  });

  test('expired stream links are refetched after the ttl', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/addon');

    await manager.streams(installation.id, type: 'movie', itemId: 'tt1');
    await manager.streams(installation.id, type: 'movie', itemId: 'tt1');
    expect(server.streams, 1);

    now = now.add(const Duration(seconds: 31));
    await manager.streams(installation.id, type: 'movie', itemId: 'tt1');
    expect(server.streams, 2);
  });

  test('concurrent identical requests are coalesced', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/addon');
    server.holdStreams = Completer<void>();

    final first = manager.streams(
      installation.id,
      type: 'movie',
      itemId: 'tt1',
    );
    final second = manager.streams(
      installation.id,
      type: 'movie',
      itemId: 'tt1',
    );
    await Future<void>.delayed(Duration.zero);
    server.holdStreams!.complete();
    server.holdStreams = null;

    expect((await first).single.url, 'https://cdn.example/video.m3u8');
    expect((await second).single.url, 'https://cdn.example/video.m3u8');
    expect(server.streams, 1);
  });

  test('cache stays bounded', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/addon');

    for (var i = 0; i < 205; i++) {
      await manager.meta(installation.id, type: 'movie', itemId: 'tt$i');
    }
    expect(manager.cacheSize, lessThanOrEqualTo(200));
  });

  test('failures never expose the configured URL or token', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/token');
    server.status = 500;

    StremioFailure? failure;
    try {
      await manager.streams(installation.id, type: 'movie', itemId: 'tt1');
    } on StremioFailure catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(failure.toString(), isNot(contains('addon.example')));
    expect(failure.toString(), isNot(contains('token')));
    expect(failure.toString(), isNot(contains('https')));
  });

  test('failed configure keeps the old configuration', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/old');
    secrets.unavailable = true;

    await expectLater(
      manager.configure(installation.id, 'https://addon.example/new'),
      throwsA(isA<StremioInstallException>()),
    );
    secrets.unavailable = false;
    expect(
      await manager.baseUri(installation.id),
      Uri.parse('https://addon.example/old'),
    );
    expect(manager.byId(installation.id)!.revision, 0);
  });

  test('missing secure storage keeps the installation unavailable', () async {
    final server = _Server();
    final manager = makeManager(server);
    final installation = await manager.install('https://addon.example/addon');
    secrets.values.clear();

    await expectLater(
      manager.streams(installation.id, type: 'movie', itemId: 'tt1'),
      throwsA(isA<StremioInstallException>()),
    );
    expect(manager.installations, hasLength(1));
  });
}
