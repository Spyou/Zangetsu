import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_remote.dart';
import 'package:watch_app/core/stremio/stremio_sync.dart';
import 'package:AniAura_source_bridge/stremio.dart';

class Secrets implements StremioSecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class Remote extends StremioRemote {
  Remote()
    : super(
        endpoint: Uri.parse('https://sync.test'),
        accessToken: () => 'token',
        currentUserId: () => 'a',
      );
  final rows = <String, Map<String, dynamic>>{};
  final writes = <String>[];
  bool offline = false;
  Completer<void>? hold;
  @override
  Future<Map<String, dynamic>> request(
    String owner,
    String action,
    Map<String, dynamic> body,
  ) async {
    if (offline) throw const SocketException('offline');
    await hold?.future;
    var row = rows[owner] ?? {'version': 0, 'configuration': null};
    final expected = body['expectedVersion'];
    final accepted = expected == null || expected == row['version'];
    if (expected != null && accepted) {
      writes.add(owner);
      row = {
        'version': (row['version'] as int) + 1,
        'configuration': body['configuration'],
      };
      rows[owner] = row;
    }
    return {...row, 'accepted': accepted};
  }
}

void main() {
  late Directory directory;
  late Secrets secrets;
  late StremioManager manager;
  late Remote remote;
  late StremioSync sync;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('stremio_sync');
    Hive.init(directory.path);
    secrets = Secrets();
    remote = Remote();
    manager = StremioManager(
      secrets: secrets,
      client: StremioClient(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'id': 'test',
              'name': 'Test',
              'version': '1',
              'resources': ['stream'],
              'types': ['movie'],
              'catalogs': [],
            }),
            200,
          ),
        ),
      ),
    );
    await manager.init();
    sync = StremioSync(manager: manager, remote: remote, secrets: secrets);
  });
  tearDown(() async {
    sync.dispose();
    manager.dispose();
    remote.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });
  test(
    'unchanged sync does not invalidate stream caches or notify Home',
    () async {
      await sync.setAccount('a');
      final revision = manager.revision;
      await sync.refresh();
      expect(manager.revision, revision);
    },
  );
  test(
    'an interrupted account switch cannot upload the other account URLs',
    () async {
      await sync.setAccount('a');
      await manager.install('https://addon.test/account-a-token');
      await sync.refresh();
      await sync.setAccount('b');
      await manager.install('https://addon.test/account-b-token');
      await sync.refresh();
      sync.dispose();
      await secrets.write(
        'stremio:sync:owner',
        jsonEncode({'owner': 'a', 'switchingTo': 'b'}),
      );
      sync = StremioSync(manager: manager, remote: remote, secrets: secrets);
      await sync.setAccount('a');
      final restored = jsonEncode(await manager.exportConfiguration());
      expect(restored, contains('account-a-token'));
      expect(restored, isNot(contains('account-b-token')));
      expect(jsonEncode(remote.rows['a']), isNot(contains('account-b-token')));
    },
  );

  test('offline edits survive retry, and deletion propagates', () async {
    await sync.setAccount('a');
    remote.offline = true;
    final addon = await manager.install('https://addon.test/private-token');
    await sync.refresh();
    expect(manager.installations, hasLength(1));
    remote.offline = false;
    await sync.refresh();
    expect(
      (remote.rows['a']!['configuration']['installations'] as List),
      hasLength(1),
    );
    await manager.remove(addon.id);
    await sync.refresh();
    expect(remote.rows['a']!['configuration']['installations'], isEmpty);
    expect(remote.rows['a']!['configuration']['deleted'], isNotEmpty);
  });
  test('account switch restores isolated local configurations', () async {
    await sync.setAccount('a');
    await manager.install('https://addon.test/account-a-token');
    await sync.refresh();
    await sync.setAccount('b');
    expect(
      manager.installations.every(
        (item) => item.id == StremioManager.defaultMetadataId,
      ),
      isTrue,
    );
    await manager.install('https://addon.test/account-b-token');
    await sync.refresh();
    expect(jsonEncode(remote.rows['b']), isNot(contains('account-a-token')));
    await sync.setAccount(null);
    expect(
      manager.installations.every(
        (item) => item.id == StremioManager.defaultMetadataId,
      ),
      isTrue,
    );
    await sync.setAccount('a');
    expect(
      (await manager.exportConfiguration())['installations'].toString(),
      contains('account-a-token'),
    );
  });
  test(
    'late responses cannot replace the next account configuration',
    () async {
      await sync.setAccount('a');
      remote.hold = Completer<void>();
      final pending = sync.refresh();
      await Future<void>.delayed(Duration.zero);
      final switching = sync.setAccount('b');
      remote.hold!.complete();
      await switching;
      await pending;
      expect(sync.owner, 'b');
      expect(
        manager.installations.every(
          (item) => item.id == StremioManager.defaultMetadataId,
        ),
        isTrue,
      );
      expect(sync.lastError, isNull);
    },
  );
}
