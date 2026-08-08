import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MihonManager manager;

  const channel = MethodChannel('zangetsu/mihon');
  final log = <MethodCall>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mihon_install_test_');
    manager = MihonManager();

    // Initialise Hive with the temp dir so box open/write doesn't touch the
    // real device storage and is cleaned up after each test. Uses the Mihon
    // box name specifically — separate from AniyomiExtensionService's
    // 'aniyomi_installed' box.
    Hive.init(tempDir.path);
    await Hive.openBox<dynamic>(MihonExtensionService.installedBoxName);

    log.clear();
    // Mock the native channel: installExtension is a no-op; listSources
    // returns one source from the 'com.test.manga' package.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      switch (call.method) {
        case 'installExtension':
          return null; // void
        case 'listSources':
          return jsonEncode([
            {
              'id': 42,
              'name': 'TestManga',
              'lang': 'en',
              'nsfw': false,
              'pkg': 'com.test.manga',
              'baseUrl': 'https://test.manga.example.com',
              'version': '1.0',
              'versionCode': 1,
            }
          ]);
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Happy path: install succeeds → sources are returned, registered in the
  // MihonManager under the mihon: prefix, and pkg -> apk path is persisted
  // separately from the anime box.
  // ---------------------------------------------------------------------------
  test(
      'installFromRepo returns the package\'s sources, registers them under '
      'mihon: in the manager, and persists apk path to mihon_installed',
      () async {
    final entry = AniyomiRepoEntry(
      name: 'TestManga',
      pkg: 'com.test.manga',
      apk: 'test-v1.0.apk',
      lang: 'en',
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: [],
      repoBaseUrl: 'https://repo.example.com',
    );

    final service = MihonExtensionService();
    final sources = await service.installFromRepo(
      entry,
      // Write a dummy APK file instead of doing a real network request.
      downloader: (url, path) async {
        await File(path).writeAsBytes([]);
      },
      apkDirectory: tempDir,
      manager: manager,
    );

    // The install path calls exactly installExtension then listSources, in
    // that order — never getEpisodes/getChapters (out of this service's
    // surface entirely).
    expect(log.map((c) => c.method).toList(), [
      'installExtension',
      'listSources',
    ]);
    expect(
      (log.first.arguments as Map)['apkPath'],
      '${tempDir.path}/com.test.manga.apk',
    );

    expect(sources, hasLength(1));
    expect(sources.single.pkg, 'com.test.manga');
    expect(sources.single.sourceId, 'mihon:42');

    // The manager must have been populated, keyed under mihon:<id> — NOT
    // ani: (spec Decision 1: ani: is hardcoded to anime by sourceTypeOf).
    expect(manager.all, hasLength(1));
    expect(manager.get('mihon:42'), isNotNull);
    expect(manager.get('mihon:42')!.pkg, 'com.test.manga');
    expect(manager.get('ani:42'), isNull);

    // pkg -> apk path persisted to the MIHON box, separate from the anime one.
    final box = Hive.box<dynamic>(MihonExtensionService.installedBoxName);
    expect(box.get('com.test.manga'), '${tempDir.path}/com.test.manga.apk');
  });

  // ---------------------------------------------------------------------------
  // Failure path: a download error must yield [] and must NOT throw.
  // ---------------------------------------------------------------------------
  test('installFromRepo returns [] and does not throw when download fails',
      () async {
    final entry = AniyomiRepoEntry(
      name: 'TestManga',
      pkg: 'com.test.manga',
      apk: 'test-v1.0.apk',
      lang: 'en',
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: [],
      repoBaseUrl: 'https://repo.example.com',
    );

    final service = MihonExtensionService();

    // Downloader that always throws to simulate a network error.
    Future<List<Object?>> call() => service.installFromRepo(
          entry,
          downloader: (url, path) async {
            throw const SocketException('connection refused');
          },
          apkDirectory: tempDir,
          manager: manager,
        );

    // Must not throw — await directly; any exception would fail the test.
    final result = await call();
    expect(result, isEmpty);

    // Never reached the channel at all — download failed first.
    expect(log, isEmpty);

    // Manager must remain empty after a failed install.
    expect(manager.all, isEmpty);
  });
}
