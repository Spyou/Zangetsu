import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_presence.dart';
import 'package:watch_app/core/discord/discord_sdk_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native SDK is selected for phones, not desktop platforms', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        supportsNativeDiscordPresence,
        platform == TargetPlatform.android || platform == TargetPlatform.iOS,
      );
    }
  });
  test(
    'SDK transport preserves activity fields and closes after clearing',
    () async {
      const channel = MethodChannel('zangetsu/discord_presence');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final gateway = DiscordSdkGateway('access');
      try {
        gateway.setPresence(
          const DiscordActivity(
            name: 'Title',
            type: 3,
            details: 'Episode 2',
            startMs: 100,
            endMs: 200,
            buttons: [(label: 'Open', url: 'https://zangetsu.online')],
          ),
          status: 'dnd',
        );
        gateway.connect();
        await Future<void>.delayed(Duration.zero);
        expect(calls.first.method, 'start');
        expect((calls.first.arguments as Map)['token'], 'access');
        final update =
            calls.singleWhere((c) => c.method == 'update').arguments as Map;
        expect(update['status'], 'dnd');
        final activity = update['activity'] as Map;
        expect(activity['name'], 'Title');
        expect(activity['type'], 3);
        expect(activity['details'], 'Episode 2');
        expect(activity['timestamps'], {'start': 100, 'end': 200});
        expect(activity['buttons'], ['Open']);
        await gateway.clearThenClose();
        expect(calls[calls.length - 2].method, 'clear');
        expect(calls.last.method, 'close');
        gateway.setPresence(const DiscordActivity(name: 'Too late'));
        await Future<void>.delayed(Duration.zero);
        expect(calls.last.method, 'close');
      } finally {
        await gateway.close();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  test('closing an old transport leaves its replacement running', () async {
    const channel = MethodChannel('zangetsu/discord_presence');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final first = DiscordSdkGateway('first');
    final replacement = DiscordSdkGateway('replacement');
    try {
      first.connect();
      await Future<void>.delayed(Duration.zero);
      final closing = first.clearThenClose();
      replacement.connect();
      await Future<void>.delayed(Duration.zero);
      await closing;
      expect(calls.where((c) => c.method == 'close'), isEmpty);
      replacement.setPresence(const DiscordActivity(name: 'Still active'));
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.method, 'update');
    } finally {
      await first.close();
      await replacement.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
