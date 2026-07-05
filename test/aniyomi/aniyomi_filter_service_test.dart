import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zangetsu/aniyomi');
  final log = <MethodCall>[];

  // ---------------------------------------------------------------------------
  // getFilterList — happy path
  // ---------------------------------------------------------------------------
  group('AniyomiExtensionService.getFilterList (happy path)', () {
    const fakeJson =
        '[{"type":"select","name":"Genre","values":["All","Action"],"state":0}]';

    setUp(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        if (call.method == 'getFilterList') return fakeJson;
        return null;
      });
    });

    tearDown(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('passes sourceId and returns the JSON string from the channel',
        () async {
      final svc = AniyomiExtensionService();
      final result = await svc.getFilterList(42);

      expect(result, fakeJson);
      expect(log.length, 1);
      expect(log.first.method, 'getFilterList');
      expect((log.first.arguments as Map)['sourceId'], 42);
    });
  });

  // ---------------------------------------------------------------------------
  // getFilterList — PlatformException → returns null
  // ---------------------------------------------------------------------------
  group('AniyomiExtensionService.getFilterList (PlatformException)', () {
    setUp(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        if (call.method == 'getFilterList') {
          throw PlatformException(
              code: 'NO_FILTERS', message: 'source has no filters');
        }
        return null;
      });
    });

    tearDown(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('returns null when native throws PlatformException', () async {
      final svc = AniyomiExtensionService();
      final result = await svc.getFilterList(42);

      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // getFilterList — MissingPluginException → returns null
  // ---------------------------------------------------------------------------
  group('AniyomiExtensionService.getFilterList (MissingPluginException)', () {
    setUp(() {
      log.clear();
      // No handler installed → channel throws MissingPluginException.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    tearDown(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('returns null when channel is unregistered (MissingPluginException)',
        () async {
      final svc = AniyomiExtensionService();
      final result = await svc.getFilterList(99);

      expect(result, isNull);
    });
  });
}
