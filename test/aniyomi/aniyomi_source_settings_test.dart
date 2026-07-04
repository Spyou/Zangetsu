import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zangetsu/aniyomi');
  final log = <MethodCall>[];

  // ---------------------------------------------------------------------------
  // hasSourceSettings — happy path
  // ---------------------------------------------------------------------------
  group('AniyomiExtensionService.hasSourceSettings', () {
    setUp(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        if (call.method == 'hasSourceSettings') return true;
        return null;
      });
    });

    tearDown(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('passes sourceId and returns true when native returns true', () async {
      final svc = AniyomiExtensionService();
      final result = await svc.hasSourceSettings(12345);

      expect(result, isTrue);
      expect(log.length, 1);
      expect(log.first.method, 'hasSourceSettings');
      expect((log.first.arguments as Map)['sourceId'], 12345);
    });
  });

  // ---------------------------------------------------------------------------
  // hasSourceSettings — PlatformException swallowed → returns false
  // ---------------------------------------------------------------------------
  group('AniyomiExtensionService.hasSourceSettings (error path)', () {
    setUp(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        if (call.method == 'hasSourceSettings') {
          throw PlatformException(
              code: 'NOT_FOUND', message: 'source not found');
        }
        return null;
      });
    });

    tearDown(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('returns false when native throws PlatformException', () async {
      final svc = AniyomiExtensionService();
      final result = await svc.hasSourceSettings(12345);

      expect(result, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // openSourceSettings — passes sourceId
  // ---------------------------------------------------------------------------
  group('AniyomiExtensionService.openSourceSettings', () {
    setUp(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        return null;
      });
    });

    tearDown(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('passes sourceId over the channel', () async {
      final svc = AniyomiExtensionService();
      await svc.openSourceSettings(99);

      expect(log.length, 1);
      expect(log.first.method, 'openSourceSettings');
      expect((log.first.arguments as Map)['sourceId'], 99);
    });
  });
}
