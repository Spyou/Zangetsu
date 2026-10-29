import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_presence.dart';
import 'package:watch_app/core/discord/discord_sdk_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zangetsu/discord_presence');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late DiscordSdkGateway gateway;

  setUp(() {
    calls.clear();
    gateway = DiscordSdkGateway('fake-token');
  });
  tearDown(() async {
    await gateway.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('failed SDK startup never sends activity or throws', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') {
        throw PlatformException(code: 'SDK_UNAVAILABLE');
      }
      return null;
    });
    gateway.connect();
    await Future<void>.delayed(Duration.zero);
    gateway.setPresence(const DiscordActivity(name: 'Not connected'));
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'update'), isEmpty);
  });

  test('closing during startup prevents a late activity update', () async {
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') await started.future;
      return null;
    });
    gateway.connect();
    gateway.setPresence(const DiscordActivity(name: 'Already left'));
    await Future<void>.delayed(Duration.zero);
    await gateway.close();
    started.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'update'), isEmpty);
  });

  test('slow startup sends only latest queued playback activity', () async {
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') await started.future;
      return null;
    });
    gateway.connect();
    gateway.setPresence(const DiscordActivity(name: 'Old browsing'));
    gateway.setPresence(const DiscordActivity(name: 'Now watching', type: 3));
    await Future<void>.delayed(Duration.zero);
    started.complete();
    await Future<void>.delayed(Duration.zero);
    final update = calls.singleWhere((call) => call.method == 'update');
    expect(
      ((update.arguments as Map)['activity'] as Map)['name'],
      'Now watching',
    );
  });
}
