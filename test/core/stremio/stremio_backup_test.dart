import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/stremio/stremio_backup.dart';
import 'package:watch_app/core/stremio/stremio_backup_cipher.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_remote.dart';
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

void main() {
  late Directory directory;
  late StremioManager manager;
  late StremioRemote remote;
  late StremioBackup backup;
  late String? owner;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('addon_backup');
    Hive.init(directory.path);
    owner = 'account-a';
    manager = StremioManager(
      secrets: Secrets(),
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
    await manager.install('https://addon.test/private-token');
    remote = StremioRemote(
      endpoint: Uri.parse('https://sync.test'),
      currentUserId: () => owner,
      accessToken: () => null,
    );
    backup = StremioBackup(
      manager: manager,
      remote: remote,
      currentUserId: () => owner,
    );
  });
  tearDown(() async {
    manager.dispose();
    remote.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });
  test(
    'real file backup encrypts and restores the complete addon configuration',
    () async {
      final encrypted = await backup.encode(
        forFile: true,
        password: 'test-password',
      );
      expect(jsonEncode(encrypted), isNot(contains('private-token')));
      final decoded = await backup.decode(encrypted, password: 'test-password');
      await manager.restoreConfiguration({
        'version': 1,
        'installations': [],
      }, merge: false);
      await backup.validate(decoded);
      await backup.guardedRestore()(decoded);
      expect(
        (await manager.baseUri(manager.installations.single.id)).toString(),
        'https://addon.test/private-token',
      );
    },
  );
  test(
    'a slow restore cannot install credentials into a different account',
    () async {
      final decoded = await manager.exportConfiguration();
      final apply = backup.guardedRestore();
      owner = 'account-b';
      await expectLater(apply(decoded), throwsA(isA<StremioBackupException>()));
    },
  );
  test(
    'a configuration changed during restore is kept rather than overwritten',
    () async {
      final decoded = await manager.exportConfiguration();
      final apply = backup.guardedRestore();
      await manager.setEnabled(manager.installations.single.id, false);
      await expectLater(
        apply(decoded),
        throwsA(isA<StremioInstallException>()),
      );
      expect(manager.installations.single.enabled, isFalse);
    },
  );
}
