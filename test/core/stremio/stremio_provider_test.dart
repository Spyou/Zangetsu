import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_provider.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _manifest = {
  'id': 'org.test.addon',
  'version': '1.0.0',
  'name': 'Test Addon',
  'resources': ['catalog', 'meta', 'stream', 'subtitles'],
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
    {
      'type': 'series',
      'id': 'shows',
      'name': 'Shows',
      'extra': [
        {'name': 'search'},
        {'name': 'skip'},
      ],
    },
  ],
};

const _seriesMeta = {
  'meta': {
    'id': 'tt0944947',
    'type': 'series',
    'name': 'Game of Thrones',
    'poster': 'https://img.example/poster.jpg',
    'background': 'https://img.example/bg.jpg',
    'description': 'Noble families fight.',
    'releaseInfo': '2011-2019',
    'genres': ['Drama', 'Fantasy'],
    'videos': [
      {'id': 'tt0944947:0:1', 'title': 'Special', 'season': 0, 'episode': 1},
      {
        'id': 'tt0944947:1:1',
        'title': 'Winter Is Coming',
        'season': 1,
        'episode': 1,
        'thumbnail': 'https://img.example/1.jpg',
      },
      {
        'id': 'tt0944947:1:2',
        'title': 'The Kingsroad',
        'season': 1,
        'episode': 2,
      },
    ],
  },
};

const _movieMeta = {
  'meta': {
    'id': 'tt0372784',
    'type': 'movie',
    'name': 'Batman Begins',
    'poster': 'https://img.example/bb.jpg',
  },
};

const _streams = {
  'streams': [
    {
      'name': '4K',
      'title': 'WEB-DL',
      'url': 'https://cdn.example/v.m3u8',
      'behaviorHints': {
        'proxyHeaders': {
          'request': {'Referer': 'https://ref/', 'User-Agent': 'UA'},
        },
      },
    },
    {'name': 'Dup', 'url': 'https://cdn.example/v.m3u8'},
    {
      'name': 'Torrent',
      'infoHash': '0123456789abcdef0123456789abcdef01234567',
      'fileIdx': 0,
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
  final failMetadataHosts = <String>{};

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    final path = request.url.path;
    if (path.endsWith('/manifest.json')) {
      if (request.url.host == 'catalog.example') {
        return _json({
          ..._manifest,
          'resources': ['catalog'],
          'catalogs': [
            ...(_manifest['catalogs'] as List),
            {
              'type': 'movie',
              'id': 'filtered',
              'name': 'Requires genre',
              'extra': [
                {
                  'name': 'genre',
                  'isRequired': true,
                  'options': ['Action'],
                },
              ],
            },
          ],
        });
      }
      return _json(
        request.url.host == 'unique.example'
            ? {..._manifest, 'id': 'org.unique.catalogue'}
            : _manifest,
      );
    }
    if (path.contains('/meta/') &&
        (request.url.host == 'catalog.example' ||
            failMetadataHosts.contains(request.url.host))) {
      return http.Response('', 404);
    }
    if (path.contains('/catalog/')) {
      return _json({
        'metas': [
          {
            'id': 'tt0372784',
            'type': 'movie',
            'name': 'Batman Begins',
            'poster': 'https://img.example/bb.jpg',
          },
          {
            'id': 'tt0944947',
            'type': 'series',
            'name': 'Game of Thrones',
            'poster': 'https://img.example/poster.jpg',
            'background': 'https://img.example/bg.jpg',
          },
        ],
      });
    }
    if (path.contains('/meta/series/')) return _json(_seriesMeta);
    if (path.contains('/meta/movie/')) return _json(_movieMeta);
    if (path.contains('/stream/')) return _json(_streams);
    return _json({'metas': []});
  }

  http.Response _json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
}

void main() {
  late Directory tempDir;
  late _FakeSecrets secrets;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stremio_provider_test');
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
  });

  StremioManager makeManager(_Server server) => StremioManager(
    client: StremioClient(httpClient: MockClient(server.handle)),
    secrets: secrets,
    clock: () => DateTime(2026, 1, 1),
  );

  Future<(StremioManager, StremioProvider, StremioInstallation)> setup({
    _Server? server,
  }) async {
    final s = server ?? _Server();
    final manager = makeManager(s);
    final installation = await manager.install('https://addon.example/addon');
    return (manager, StremioProvider(manager), installation);
  }

  test(
    'MPV episode resolution keeps torrent file selection for the correct episode',
    () async {
      final server = _Server();
      final (manager, provider, installed) = await setup(server: server);
      final episode = StremioRef(
        installationId: installed.id,
        type: 'series',
        itemId: 'tt0944947',
        videoId: 'tt0944947:1:2',
      );
      final sources = await provider.getVideoSources(
        episode.encode(),
        allowTorrent: true,
      );
      final torrent = sources.firstWhere(
        (source) => source.torrentFileIndex != null,
      );
      expect(torrent.torrentFileIndex, 0);
      expect(torrent.url, contains('so=0'));
      expect(
        server.requests.any((u) => u.path.contains('tt0944947%3A1%3A2')),
        isTrue,
      );
      expect(
        (await provider.getVideoSources(
          episode.encode(),
        )).every((source) => source.torrentFileIndex == null),
        isTrue,
      );
      expect(manager.enabled, isNotEmpty);
    },
  );

  test(
    'Home skips disabled addons and addons whose Home rows are all hidden',
    () async {
      final manager = makeManager(_Server());
      final first = await manager.install('https://first.example');
      final second = await manager.install('https://unique.example');
      final provider = StremioProvider(manager);
      await manager.setEnabled(first.id, false);
      var rows = await provider.getHome();
      expect(
        rows!.every(
          (row) => jsonDecode(row.more!.categoryId!)['i'] == second.id,
        ),
        isTrue,
      );
      await manager.setEnabled(first.id, true);
      await manager.setCatalogVisible(first.id, 'movie', 'top', false);
      await manager.setCatalogVisible(first.id, 'series', 'shows', false);
      rows = await provider.getHome();
      expect(rows, hasLength(2));
      expect(
        rows!.every(
          (row) => jsonDecode(row.more!.categoryId!)['i'] == second.id,
        ),
        isTrue,
      );
    },
  );

  test(
    'Home rows follow the top catalogue addon and update after reordering',
    () async {
      final server = _Server();
      final manager = makeManager(server);
      final first = await manager.install('https://first.example');
      final second = await manager.install('https://second.example');
      final provider = StremioProvider(manager);
      final rows = await provider.getHome();
      expect(rows, hasLength(2));
      expect(
        rows!.every(
          (row) => jsonDecode(row.more!.categoryId!)['i'] == first.id,
        ),
        isTrue,
      );
      expect(
        server.requests.where(
          (u) => u.host == 'second.example' && u.path.contains('/catalog/'),
        ),
        isEmpty,
      );
      await manager.move(second.id, -1);
      final reordered = await provider.getHome();
      expect(reordered, hasLength(2));
      expect(
        reordered!.every(
          (row) => jsonDecode(row.more!.categoryId!)['i'] == second.id,
        ),
        isTrue,
      );
    },
  );

  test(
    'Home uses the top catalogue addon even when addon identities differ',
    () async {
      final manager = makeManager(_Server());
      await manager.install('https://first.example');
      await manager.install('https://unique.example');
      expect(await StremioProvider(manager).getHome(), hasLength(2));
    },
  );

  test('hiding one row keeps Home on the same selected addon', () async {
    final manager = makeManager(_Server());
    final first = await manager.install('https://first.example');
    await manager.install('https://second.example');
    await manager.setCatalogVisible(first.id, 'movie', 'top', false);
    final rows = await StremioProvider(manager).getHome();
    expect(rows, hasLength(1));
    expect(rows!.single.title, 'Shows');
  });

  test('disabled metadata addons are not used as fallback', () async {
    final server = _Server();
    final manager = makeManager(server);
    final catalog = await manager.install('https://catalog.example');
    final meta = await manager.install('https://metadata.example');
    await manager.setEnabled(meta.id, false);
    await expectLater(
      StremioProvider(manager).getDetail(
        StremioRef(
          installationId: catalog.id,
          type: 'movie',
          itemId: 'tt0372784',
        ).encode(),
      ),
      throwsA(isA<StremioInstallException>()),
    );
    expect(server.requests.where((u) => u.path.contains('/meta/')), isEmpty);
  });

  test('defines one Stremio source', () async {
    final (_, provider, _) = await setup();
    final info = await provider.getInfo();
    expect(provider.sourceId, 'stremio');
    expect(provider.displayName, 'Stremio');
    expect(info.name, 'Stremio');
    expect(info.type, ProviderType.movie);
  });

  test('home rows are named per catalogue and carry a browse handle', () async {
    final (_, provider, installation) = await setup();
    final sections = await provider.getHome();

    expect(sections, isNotNull);
    expect(sections!.map((s) => s.title), ['Top Movies', 'Shows']);
    final first = sections.first.items.first;
    expect(first.sourceId, 'stremio');
    expect(first.id, 'movie:tt0372784');
    expect(first.url, startsWith('stremio://ref?'));
    expect(StremioRef.parse(first.url).installationId, installation.id);
    expect(sections.first.more?.kind, 'stremio_catalog');
    expect(sections.first.more?.sourceId, 'stremio');
  });

  test('search dedupes across installations and pages with skip', () async {
    final server = _Server();
    final (manager, provider, _) = await setup(server: server);
    await manager.install('https://b.example/addon');

    final page1 = await provider.search('batman', 1);
    expect(page1.map((i) => i.id).toSet(), {
      'movie:tt0372784',
      'series:tt0944947',
    });
    expect(page1, hasLength(2));

    server.requests.clear();
    await provider.search('batman', 2);
    expect(
      server.requests.where((u) => u.path.contains('/catalog/')),
      isNotEmpty,
    );
    for (final uri in server.requests.where(
      (u) => u.path.contains('/catalog/'),
    )) {
      expect(uri.path, contains('skip=100'));
      expect(uri.path, contains('search=batman'));
    }
  });

  test(
    'catalogue-only titles use a compatible metadata addon for details and episodes',
    () async {
      final server = _Server();
      final manager = makeManager(server);
      final catalog = await manager.install('https://catalog.example');
      await manager.install('https://metadata.example');
      final provider = StremioProvider(manager);
      final ref = StremioRef(
        installationId: catalog.id,
        type: 'series',
        itemId: 'tt0944947',
      );
      final detail = await provider.getDetail(ref.encode());
      expect(detail.title, 'Game of Thrones');
      expect(detail.episodes, isNotEmpty);
      expect(await provider.getEpisodes(ref.encode()), detail.episodes);
      expect(
        server.requests.where(
          (u) => u.host == 'catalog.example' && u.path.contains('/meta/'),
        ),
        isEmpty,
      );
    },
  );

  test('metadata failure tries the next compatible enabled addon', () async {
    final server = _Server()..failMetadataHosts.add('broken.example');
    final manager = makeManager(server);
    final first = await manager.install('https://broken.example');
    await manager.install('https://working.example');
    final detail = await StremioProvider(manager).getDetail(
      StremioRef(
        installationId: first.id,
        type: 'movie',
        itemId: 'tt0372784',
      ).encode(),
    );
    expect(detail.title, 'Batman Begins');
  });

  test('addon-local IDs never cross into another metadata addon', () async {
    final server = _Server();
    final manager = makeManager(server);
    final catalog = await manager.install('https://catalog.example');
    await manager.install('https://metadata.example');
    await expectLater(
      StremioProvider(manager).getDetail(
        StremioRef(
          installationId: catalog.id,
          type: 'movie',
          itemId: 'local:7',
        ).encode(),
      ),
      throwsA(isA<StremioInstallException>()),
    );
    expect(server.requests.where((u) => u.path.contains('/meta/')), isEmpty);
  });

  test(
    'Home excludes catalogues requiring a year or genre selection',
    () async {
      final manager = makeManager(_Server());
      await manager.install('https://catalog.example');
      final rows = await StremioProvider(manager).getHome();
      expect(rows, hasLength(2));
      expect(rows!.map((r) => r.title), isNot(contains('Requires genre')));
    },
  );

  test(
    'default Home reads the live manifest instead of fixed fallback rows',
    () async {
      final server = _Server();
      final manager = makeManager(server);
      await manager.ensureDefaultMetadata();
      expect(manager.installations.single.catalogs, hasLength(6));
      final rows = await StremioProvider(manager).getHome();
      expect(rows!.map((row) => row.title), ['Top Movies', 'Shows']);
      expect(
        server.requests.any((u) => u.path.endsWith('/manifest.json')),
        isTrue,
      );
    },
  );

  test('Home skips hidden rows while metadata keeps working', () async {
    final (manager, provider, installation) = await setup();
    await manager.setCatalogVisible(installation.id, 'movie', 'top', false);
    final rows = await provider.getHome();
    expect(rows!.map((row) => row.title), ['Shows']);
    expect(
      (await provider.getDetail(
        StremioRef(
          installationId: installation.id,
          type: 'movie',
          itemId: 'tt0372784',
        ).encode(),
      )).title,
      'Batman Begins',
    );
  });

  test('detail uses addon metadata and the full episode ids', () async {
    final (_, provider, installation) = await setup();
    final ref = StremioRef(
      installationId: installation.id,
      type: 'series',
      itemId: 'tt0944947',
    );
    final detail = await provider.getDetail(ref.encode());

    expect(detail.id, 'series:tt0944947');
    expect(detail.title, 'Game of Thrones');
    expect(detail.cover, 'https://img.example/poster.jpg');
    expect(detail.banner, 'https://img.example/bg.jpg');
    expect(detail.year, '2011');
    expect(detail.genres, ['Drama', 'Fantasy']);
    expect(detail.imdbId, 'tt0944947');
    expect(detail.tmdbIsTv, isTrue);
    expect(detail.sourceId, 'stremio');

    expect(detail.episodes, hasLength(3));
    expect(detail.episodes.first.season, 0);
    expect(detail.episodes.first.number, 1);
    final episode = detail.episodes[2];
    expect(episode.title, 'The Kingsroad');
    expect(episode.number, 2);
    expect(episode.id, 'tt0944947:1:2');
    expect(StremioRef.parse(episode.url).videoId, 'tt0944947:1:2');
  });

  test('a movie without videos gets one metadata-id entry', () async {
    final (_, provider, installation) = await setup();
    final ref = StremioRef(
      installationId: installation.id,
      type: 'movie',
      itemId: 'tt0372784',
    );
    final detail = await provider.getDetail(ref.encode());

    expect(detail.episodes, hasLength(1));
    expect(detail.id, 'movie:tt0372784');
    expect(detail.episodes.single.url, ref.encode());
    expect(StremioRef.parse(detail.episodes.single.url).videoId, isNull);
  });

  test('removed origin installation falls back for a verified id', () async {
    final (manager, provider, installation) = await setup();
    final ref = StremioRef(
      installationId: installation.id,
      type: 'series',
      itemId: 'tt0944947',
    );
    await manager.remove(installation.id);
    await manager.install('https://b.example/addon');

    final detail = await provider.getDetail(ref.encode());
    expect(detail.id, 'series:tt0944947');
    expect(detail.title, 'Game of Thrones');
  });

  test('removed origin with no compatible addon fails visibly', () async {
    final (manager, provider, installation) = await setup();
    final ref = StremioRef(
      installationId: installation.id,
      type: 'movie',
      itemId: 'local:7',
    );
    await manager.remove(installation.id);

    await expectLater(
      provider.getDetail(ref.encode()),
      throwsA(isA<StremioInstallException>()),
    );
  });

  test('episodes resolve from the selected video id', () async {
    final server = _Server();
    final (_, provider, installation) = await setup(server: server);
    final ref = StremioRef(
      installationId: installation.id,
      type: 'series',
      itemId: 'tt0944947',
      videoId: 'tt0944947:1:2',
    );

    final episodes = await provider.getEpisodes(ref.encode());
    expect(episodes, hasLength(3));
    expect(episodes[2].id, 'tt0944947:1:2');
  });

  test('sources keep exact headers, dedupe and skip torrents', () async {
    final server = _Server();
    final manager = makeManager(server);
    final first = await manager.install('https://a.example/addon');
    await manager.install('https://b.example/addon');
    final provider = StremioProvider(manager);

    final ref = StremioRef(
      installationId: first.id,
      type: 'movie',
      itemId: 'tt0372784',
    );
    final sources = await provider.getVideoSources(ref.encode());

    expect(sources, hasLength(1));
    expect(sources.single.url, 'https://cdn.example/v.m3u8');
    expect(sources.single.headers, {
      'Referer': 'https://ref/',
      'User-Agent': 'UA',
    });
    expect(sources.single.quality, '4k');
    expect(sources.single.label, '4K · WEB-DL');
    expect(sources.single.container, isNotNull);
  });
}
