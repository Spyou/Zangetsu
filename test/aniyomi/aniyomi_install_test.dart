import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AniyomiManager manager;

  const channel = MethodChannel('zangetsu/aniyomi');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aniyomi_install_test_');
    manager = AniyomiManager();

    // Initialise Hive with the temp dir so box open/write doesn't touch the
    // real device storage and is cleaned up after each test.
    Hive.init(tempDir.path);
    await Hive.openBox<dynamic>(AniyomiExtensionService.installedBoxName);

    // Mock the native channel: installExtension is a no-op; listSources
    // returns one source from the 'com.test.anime' package.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'installExtension':
          return null; // void
        case 'listSources':
          return jsonEncode([
            {
              'id': 42,
              'name': 'TestAnime',
              'lang': 'en',
              'nsfw': false,
              'pkg': 'com.test.anime',
              'baseUrl': 'https://test.anime.example.com',
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
  // Happy path: install succeeds → providers with ani: prefix are returned and
  // registered in the AniyomiManager.
  // ---------------------------------------------------------------------------
  test(
      'installFromRepo returns providers whose ids start with ani: '
      'and registers them in the manager', () async {
    final entry = AniyomiRepoEntry(
      name: 'TestAnime',
      pkg: 'com.test.anime',
      apk: 'test-v1.0.apk',
      lang: 'en',
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: [],
      repoBaseUrl: 'https://repo.example.com',
    );

    final service = AniyomiExtensionService();
    final providers = await service.installFromRepo(
      entry,
      // Write a dummy APK file instead of doing a real network request.
      downloader: (url, path) async {
        await File(path).writeAsBytes([]);
      },
      apkDirectory: tempDir,
      manager: manager,
    );

    // All returned providers must have the ani: prefix.
    expect(providers, isNotEmpty);
    expect(providers.every((p) => p.sourceId.startsWith('ani:')), isTrue,
        reason: 'every provider id must start with ani:');

    // The manager must have been populated with the same providers.
    expect(manager.all, isNotEmpty);
    expect(manager.all.every((p) => p.sourceId.startsWith('ani:')), isTrue,
        reason: 'every registered provider id must start with ani:');

    // Sanity-check the concrete values from our mocked listSources reply.
    expect(providers.first.sourceId, 'ani:42');
    expect(providers.first.displayName, 'TestAnime');
  });

  // ---------------------------------------------------------------------------
  // Failure path: a download error must yield [] and must NOT throw.
  // ---------------------------------------------------------------------------
  test('installFromRepo returns [] and does not throw when download fails',
      () async {
    final entry = AniyomiRepoEntry(
      name: 'TestAnime',
      pkg: 'com.test.anime',
      apk: 'test-v1.0.apk',
      lang: 'en',
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: [],
      repoBaseUrl: 'https://repo.example.com',
    );

    final service = AniyomiExtensionService();

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

    // Manager must remain empty after a failed install.
    expect(manager.all, isEmpty);
  });
}
