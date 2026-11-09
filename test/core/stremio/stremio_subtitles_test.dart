import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:watch_app/core/stremio/stremio_subtitles.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _manifest = {
  'id': 'org.test.addon',
  'version': '1.0.0',
  'name': 'Test Addon',
  'resources': ['stream', 'subtitles'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
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
  Map<String, Object> manifest = _manifest;
  Completer<void>? gate;
  bool failSecond = false;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    if (request.url.path.endsWith('/manifest.json')) {
      return _json(manifest);
    }
    if (request.url.path.contains('/subtitles/')) {
      if (gate != null) await gate!.future;
      if (failSecond && request.url.host.startsWith('b')) {
        return http.Response('', 500);
      }
      return _json({
        'subtitles': [
          {'url': 'https://subs.example/en.srt', 'lang': 'English'},
        ],
      });
    }
    return _json({'streams': []});
  }

  http.Response _json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
}

void main() {
  late Directory tempDir;
  late _Server server;
  late StremioManager manager;
  late StremioInstallation first;
  late StremioInstallation second;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stremio_subs_test');
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
    server = _Server();
    manager = StremioManager(
      client: StremioClient(httpClient: MockClient(server.handle)),
      secrets: _FakeSecrets(),
      clock: () => DateTime(2026, 1, 1),
    );
    first = await manager.install('https://a.example/addon');
    second = await manager.install('https://b.example/addon');
  });

  StremioRef refFor(StremioInstallation installation) => StremioRef(
    installationId: installation.id,
    type: 'series',
    itemId: 'tt1',
    videoId: 'tt1:1:1',
  );

  test(
    'subtitle eligibility uses subtitle limits rather than stream limits',
    () async {
      server.manifest = {
        ..._manifest,
        'resources': [
          {
            'name': 'stream',
            'idPrefixes': ['custom:'],
          },
          {
            'name': 'subtitles',
            'idPrefixes': ['tt'],
          },
        ],
      };
      await manager.remove(first.id);
      await manager.remove(second.id);
      first = await manager.install('https://c.example/addon');
      final tracks = await stremioSubtitlesFor(
        manager,
        refFor(first),
        const StremioStream(
          kind: StremioStreamKind.direct,
          url: 'https://cdn.example/v.mkv',
        ),
      );
      expect(tracks, hasLength(1));
    },
  );

  test('requests use the actual video id and release extras', () async {
    await stremioSubtitlesFor(
      manager,
      refFor(first),
      const StremioStream(
        kind: StremioStreamKind.direct,
        url: 'https://cdn.example/v.mkv',
        fileName: 'movie.mkv',
        videoHash: 'abc',
        videoSize: 1234,
      ),
    );

    final subtitleRequests = server.requests
        .where((u) => u.path.contains('/subtitles/'))
        .toList();
    expect(subtitleRequests, isNotEmpty);
    final uri = subtitleRequests.first;
    expect(
      uri.pathSegments.last,
      'filename=movie.mkv&videoHash=abc&videoSize=1234.json',
    );
    expect(uri.path, contains('tt1%3A1%3A1/filename='));
  });

  test('one failing addon does not drop the working tracks', () async {
    server.failSecond = true;
    final tracks = await stremioSubtitlesFor(
      manager,
      refFor(first),
      const StremioStream(
        kind: StremioStreamKind.direct,
        url: 'https://cdn.example/v.mkv',
      ),
    );
    expect(tracks.map((s) => s.url).toSet(), {'https://subs.example/en.srt'});
  });

  test('a slow addon is bounded by the budget', () async {
    server.gate = Completer<void>();
    final started = DateTime.now();
    final tracks = await stremioSubtitlesFor(
      manager,
      refFor(first),
      const StremioStream(
        kind: StremioStreamKind.direct,
        url: 'https://cdn.example/v.mkv',
      ),
      budget: const Duration(milliseconds: 25),
    );
    final elapsed = DateTime.now().difference(started);
    expect(tracks, isEmpty);
    expect(elapsed, lessThan(const Duration(milliseconds: 800)));
    server.gate!.complete();
  });

  test(
    'expired subtitle searches do not start more addons or change returned tracks',
    () async {
      server.gate = Completer<void>();
      final tracks = await stremioSubtitlesFor(
        manager,
        refFor(first),
        const StremioStream(
          kind: StremioStreamKind.direct,
          url: 'https://cdn.example/v.mkv',
        ),
        budget: const Duration(milliseconds: 25),
      );
      server.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(tracks, isEmpty);
      expect(
        server.requests.where(
          (u) => u.host.startsWith('b') && u.path.contains('/subtitles/'),
        ),
        isEmpty,
      );
    },
  );

  test('duplicate subtitle URLs are emitted once', () async {
    final install = first;
    expect(install.id, manager.installations.first.id);
    final tracks = await stremioSubtitlesFor(
      manager,
      refFor(first),
      const StremioStream(
        kind: StremioStreamKind.direct,
        url: 'https://cdn.example/v.mkv',
      ),
    );
    expect(tracks, hasLength(1));
    expect(second.id, isNotEmpty);
  });
}
