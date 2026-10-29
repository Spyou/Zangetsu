import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zangetsu/discord_presence');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory directory;
  late DiscordRpc rpc;
  late Dio dio;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 450));

  List<Map> activities() => calls
      .where((call) => call.method == 'update')
      .map((call) => (call.arguments as Map)['activity'] as Map)
      .toList();

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('discord_adversarial');
    Hive.init(directory.path);
    await Hive.openBox(DiscordRpc.boxName);
    dio = Dio();
    rpc = DiscordRpc(dio);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    IncognitoMode.notifier.value = false;
    await Hive.box(DiscordRpc.boxName).putAll({
      'accessToken': 'fake-test-token',
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      'browsingTitle': true,
      'largeImage': 'poster',
      'showPaused': true,
    });
    await rpc.getValidAccessToken();
    await rpc.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    calls.clear();
  });

  tearDown(() async {
    await rpc.setEnabled(false);
    await settle();
    calls.clear();
    IncognitoMode.notifier.value = false;
    debugDefaultTargetPlatformOverride = null;
  });

  tearDownAll(() async {
    messenger.setMockMethodCallHandler(channel, null);
    dio.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('browsing sends title and artwork on ${platform.name}', () async {
      debugDefaultTargetPlatformOverride = platform;
      await rpc.setBrowsing(
        title: 'Title A',
        posterUrl: 'https://example.com/a.jpg',
      );
      await settle();
      final activity = activities().single;
      expect(activity['details'], 'Looking at Title A');
      expect(activity['type'], 0);
      expect(
        (activity['assets'] as Map)['large_image'],
        'https://example.com/a.jpg',
      );
    });
  }

  test(
    'hidden browsing title and missing poster use generic activity',
    () async {
      await rpc.setPresencePref('browsingTitle', false);
      await rpc.setBrowsing(title: 'Private title');
      await settle();
      expect(activities().single['details'], 'Browsing');
    },
  );

  test('rapid title changes publish only the latest title', () async {
    await Future.wait([
      rpc.setBrowsing(title: 'Old', posterUrl: 'https://example.com/a.jpg'),
      rpc.setBrowsing(title: 'Latest', posterUrl: 'https://example.com/b.jpg'),
    ]);
    await settle();
    expect(activities(), hasLength(1));
    expect(activities().single['details'], 'Looking at Latest');
  });

  test('watching replaces pending browsing', () async {
    await Future.wait([
      rpc.setBrowsing(
        title: 'Old detail',
        posterUrl: 'https://example.com/a.jpg',
      ),
      rpc.setWatching(
        title: 'Playing now',
        duration: const Duration(minutes: 20),
      ),
    ]);
    await settle();
    expect(activities().single['type'], 3);
    expect(activities().single['name'], 'Playing now');
  });

  test('clear cannot be undone by unfinished browsing work', () async {
    final pending = rpc.setBrowsing(title: 'Already left');
    rpc.clear();
    await pending;
    await settle();
    expect(activities(), isEmpty);
  });

  test('clear cannot be undone by unfinished watching work', () async {
    final pending = rpc.setWatching(title: 'Already stopped');
    rpc.clear();
    await pending;
    await settle();
    expect(activities(), isEmpty);
  });

  test('scheduled exit clear discards older unfinished browsing', () async {
    final pending = rpc.setBrowsing(title: 'Already left');
    rpc.clear(delay: const Duration(milliseconds: 50));
    await pending;
    await settle();
    expect(activities(), isEmpty);
  });

  test('new playback still cancels a scheduled exit clear', () async {
    rpc.clear(delay: const Duration(milliseconds: 50));
    await rpc.setWatching(title: 'Next episode');
    await settle();
    expect(activities().single['name'], 'Next episode');
    expect(calls.where((call) => call.method == 'clear'), isEmpty);
  });

  test('older slow browsing cannot replace newer watching', () async {
    await Future.wait([
      rpc.setBrowsing(title: 'Old detail'),
      rpc.setWatching(
        title: 'Playing now',
        posterUrl: 'https://example.com/a.jpg',
      ),
    ]);
    await settle();
    expect(activities().single['type'], 3);
    expect(activities().single['name'], 'Playing now');
  });

  test('disabled and incognito browsing never publish', () async {
    IncognitoMode.notifier.value = true;
    await rpc.setBrowsing(title: 'Hidden');
    await settle();
    expect(activities(), isEmpty);
    IncognitoMode.notifier.value = false;
    await rpc.setEnabled(false);
    await settle();
    calls.clear();
    await rpc.setBrowsing(title: 'Disabled');
    await settle();
    expect(activities(), isEmpty);
  });

  test('disable during browsing does not replay it when re-enabled', () async {
    final pending = rpc.setBrowsing(title: 'Before disable');
    await rpc.setEnabled(false);
    await pending;
    await settle();
    calls.clear();
    await rpc.setEnabled(true);
    await settle();
    expect(activities(), isEmpty);
  });

  test('native-player lifecycle pause keeps watching activity', () async {
    await rpc.setWatching(title: 'Still playing');
    await settle();
    calls.clear();
    rpc.onPaused();
    await settle();
    expect(
      calls.where((call) => call.method == 'clear' || call.method == 'close'),
      isEmpty,
    );
  });
}
