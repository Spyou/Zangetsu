import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/stremio/stremio_link_session.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _manifest = {
  'id': 'org.test.addon',
  'version': '1.0.0',
  'name': 'Test Addon',
  'resources': ['stream'],
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
  final Map<String, Completer<void>> gates = {};
  final List<String> streamHosts = [];
  final List<Uri> requests = [];
  int active = 0;
  int maxActive = 0;
  bool duplicates = false;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);
    if (request.url.path.endsWith('/manifest.json')) {
      return _json(_manifest);
    }
    final host = request.url.host;
    streamHosts.add(host);
    active++;
    if (active > maxActive) maxActive = active;
    final gate = gates[host];
    try {
      if (gate != null) await gate.future;
      if (duplicates) {
        return _json({
          'streams': [
            {'name': 'One', 'url': 'https://cdn.example/v.m3u8'},
            {'name': 'Same', 'url': 'https://cdn.example/v.m3u8'},
            {
              'name': 'Other headers',
              'url': 'https://cdn.example/v.m3u8',
              'behaviorHints': {
                'proxyHeaders': {
                  'request': {'Referer': 'https://other/'},
                },
              },
            },
          ],
        });
      }
      return _json({
        'streams': [
          {
            'name': host,
            'url': 'https://cdn.example/$host.m3u8',
            'behaviorHints': {
              'proxyHeaders': {
                'request': {'Referer': 'https://$host/'},
              },
            },
          },
        ],
      });
    } finally {
      active--;
    }
  }

  http.Response _json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
}

Future<void> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory tempDir;
  late _Server server;
  late StremioManager manager;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('stremio_links_test');
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
  });

  Future<StremioInstallation> addon(String host) =>
      manager.install('https://$host/addon');

  StremioRef refFor(StremioInstallation installation) =>
      StremioRef(installationId: installation.id, type: 'movie', itemId: 'tt1');

  test('a ready link becomes stale when its addon changes', () async {
    final installed = await addon('a.example');
    final session = manager.openLinks(refFor(installed));
    await session.done;
    final choice = session.currentGroups.single.choices.single;
    expect(session.isCurrent(choice), isTrue);
    await manager.configure(installed.id, 'https://b.example');
    expect(session.isCurrent(choice), isFalse);
    session.dispose();
  });

  test(
    'metadata origin is not a pending stream group unless it has inline links',
    () async {
      await manager.ensureDefaultMetadata();
      final streamAddon = await addon('streams.example');
      final ref = StremioRef(
        installationId: StremioManager.defaultMetadataId,
        type: 'movie',
        itemId: 'tt1',
      );
      final session = manager.openLinks(ref);
      await session.done;
      expect(session.currentGroups.map((g) => g.installation.id), [
        streamAddon.id,
      ]);
      session.dispose();
      final withInline = manager.openLinks(
        ref,
        inlineStreams: [
          StremioStream(
            kind: StremioStreamKind.direct,
            url: 'https://cdn.example/inline.m3u8',
          ),
        ],
      );
      await withInline.done;
      expect(
        withInline.currentGroups.first.installation.id,
        StremioManager.defaultMetadataId,
      );
      expect(withInline.currentGroups.first.choices, hasLength(1));
      expect(withInline.currentGroups.first.state, StremioLinkGroupState.ready);
      withInline.dispose();
    },
  );

  test('partial results arrive in stable installation order', () async {
    final first = await addon('a.example');
    final second = await addon('b.example');
    server.gates['a.example'] = Completer<void>();
    server.gates['b.example'] = Completer<void>();

    final session = manager.openLinks(refFor(first));
    final events = <StremioLinkGroup>[];
    session.groups.listen(events.add);

    await waitUntil(() => server.streamHosts.length == 2);
    expect(events, isEmpty);

    server.gates['a.example']!.complete();
    await waitUntil(() => events.isNotEmpty);
    expect(events.single.installation.id, first.id);
    expect(events.single.state, StremioLinkGroupState.ready);
    expect(events.single.choices.single.stream.url, contains('a.example'));
    expect(session.currentGroups.first.state, StremioLinkGroupState.ready);
    expect(session.currentGroups.last.state, StremioLinkGroupState.pending);

    server.gates['b.example']!.complete();
    await session.done;
    expect(session.currentGroups.map((g) => g.installation.id), [
      first.id,
      second.id,
    ]);
    expect(session.currentGroups.last.state, StremioLinkGroupState.ready);
    session.dispose();
  });

  test('never runs more than four addon requests at once', () async {
    final hosts = List.generate(6, (i) => 'h$i.example');
    for (final host in hosts) {
      await addon(host);
      server.gates[host] = Completer<void>();
    }

    final session = manager.openLinks(refFor(await addon('origin.example')));
    await waitUntil(() => server.streamHosts.length == 4);
    expect(server.maxActive, 4);

    server.gates[hosts.first]!.complete();
    await waitUntil(() => server.streamHosts.length == 5);
    expect(server.maxActive, 4);

    for (final host in hosts) {
      if (!server.gates[host]!.isCompleted) server.gates[host]!.complete();
    }
    await session.done;
    session.dispose();
  });

  test('fifty addons stay ordered and capped', () async {
    for (var i = 0; i < 50; i++) {
      await addon('a$i.example');
    }
    final session = manager.openLinks(refFor(manager.installations.first));
    await session.done;
    expect(session.currentGroups, hasLength(50));
    expect(server.maxActive, lessThanOrEqualTo(4));
    expect(
      session.currentGroups.map((g) => g.installation.id),
      manager.installations.map((i) => i.id),
    );
    session.dispose();
  });

  test('dispose stops queued work and late replies', () async {
    for (var i = 0; i < 6; i++) {
      await addon('d$i.example');
      server.gates['d$i.example'] = Completer<void>();
    }
    final session = manager.openLinks(refFor(manager.installations.first));
    final events = <StremioLinkGroup>[];
    session.groups.listen(events.add);
    await waitUntil(() => server.streamHosts.length == 4);

    session.dispose();
    for (final gate in server.gates.values) {
      gate.complete();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(events, isEmpty);
    expect(server.streamHosts, hasLength(4));
  });

  test('a config change rejects the late reply', () async {
    final installation = await addon('a.example');
    server.gates['a.example'] = Completer<void>();
    final session = manager.openLinks(refFor(installation));
    await waitUntil(() => server.streamHosts.isNotEmpty);

    await manager.setEnabled(installation.id, false);
    server.gates['a.example']!.complete();
    await session.done;

    final group = session.currentGroups.single;
    expect(group.state, StremioLinkGroupState.stale);
    expect(group.hasPlayable, isFalse);
    session.dispose();
  });

  test('duplicates are removed inside an addon group', () async {
    final installation = await addon('a.example');
    server.duplicates = true;

    final session = manager.openLinks(refFor(installation));
    await session.done;

    final group = session.currentGroups.single;
    expect(group.choices, hasLength(2));
    expect(group.choices.map((c) => c.label), ['One', 'Other headers']);
    session.dispose();
  });

  test('disabling an addon removes its group', () async {
    final first = await addon('a.example');
    final second = await addon('b.example');
    await manager.setEnabled(second.id, false);

    final session = manager.openLinks(refFor(first));
    await session.done;

    expect(session.currentGroups.map((g) => g.installation.id), [first.id]);
    session.dispose();
  });

  test(
    'two sessions share one coalesced request; cancelling one is safe',
    () async {
      final installation = await addon('a.example');
      server.gates['a.example'] = Completer<void>();
      final ref = refFor(installation);

      final first = manager.openLinks(ref);
      final second = manager.openLinks(ref);
      final firstEvents = <StremioLinkGroup>[];
      final secondEvents = <StremioLinkGroup>[];
      first.groups.listen(firstEvents.add);
      second.groups.listen(secondEvents.add);

      await waitUntil(() => server.streamHosts.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.streamHosts, hasLength(1));

      first.dispose();
      server.gates['a.example']!.complete();
      await second.done;

      expect(firstEvents, isEmpty);
      expect(second.currentGroups.single.state, StremioLinkGroupState.ready);
      second.dispose();
    },
  );

  test('inline video streams stay in their origin group', () async {
    final installation = await addon('a.example');
    server.gates['a.example'] = Completer<void>();
    final inline = StremioStream(
      kind: StremioStreamKind.direct,
      url: 'https://cdn.example/inline.m3u8',
      name: 'Inline',
    );

    final session = manager.openLinks(
      refFor(installation).withVideo('tt1:1:1'),
      inlineStreams: [inline],
    );
    final events = <StremioLinkGroup>[];
    session.groups.listen(events.add);

    await waitUntil(() => events.isNotEmpty);
    expect(events.first.installation.id, installation.id);
    expect(events.first.choices.single.inline, isTrue);
    expect(events.first.choices.single.stream.url, contains('inline'));

    server.gates['a.example']!.complete();
    await session.done;
    final choices = session.currentGroups.single.choices;
    expect(choices, hasLength(2));
    expect(choices.first.inline, isTrue);
    expect(choices.first.stream.url, contains('inline'));
    expect(choices.last.inline, isFalse);
    session.dispose();
  });
}
