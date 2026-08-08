import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';

/// Channel-surface tests for [MihonExtensionService].
///
/// This is the M5b regression net for the documented anime/manga divergence:
/// the manga bridge exposes `getChapters`, not `getEpisodes` (unlike this
/// service's shape, `AniyomiExtensionService` never calls the episode/chapter
/// listing method either — that lives one layer up, on the provider). What
/// this file guards is the 6 methods this service DOES call: their exact
/// string names and the exact argument keys sent, against a mock
/// `zangetsu/mihon` channel. A typo'd method name here would compile fine and
/// fail only at runtime on-device — exactly the class of bug the spec warns
/// about — so every assertion below checks the real `MethodCall.method` and
/// `MethodCall.arguments`, not just "did not throw".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zangetsu/mihon');
  final log = <MethodCall>[];

  void install(Future<dynamic> Function(MethodCall call) handler) {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return handler(call);
    });
  }

  tearDown(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('installExtension invokes "installExtension" with apkPath', () async {
    install((call) async => null);
    final svc = MihonExtensionService();
    await svc.installExtension('/tmp/some.apk');

    expect(log.length, 1);
    expect(log.first.method, 'installExtension');
    expect((log.first.arguments as Map)['apkPath'], '/tmp/some.apk');
  });

  test('loadInstalled invokes "loadInstalled" with dir', () async {
    install((call) async => null);
    final svc = MihonExtensionService();
    await svc.loadInstalled('/tmp/mihon');

    expect(log.length, 1);
    expect(log.first.method, 'loadInstalled');
    expect((log.first.arguments as Map)['dir'], '/tmp/mihon');
  });

  test('listSources invokes "listSources" with no args and decodes the reply',
      () async {
    install((call) async {
      if (call.method == 'listSources') {
        return '[{"id":7,"name":"MangaSrc","lang":"en","nsfw":false,'
            '"pkg":"com.test.manga","baseUrl":"https://m.example.com",'
            '"version":"2.3","versionCode":9,"headers":{"Referer":"x"}}]';
      }
      return null;
    });
    final svc = MihonExtensionService();
    final result = await svc.listSources();

    expect(log.length, 1);
    expect(log.first.method, 'listSources');
    expect(log.first.arguments, isNull);

    expect(result, hasLength(1));
    expect(result.single.id, 7);
    expect(result.single.name, 'MangaSrc');
    expect(result.single.pkg, 'com.test.manga');
    expect(result.single.versionCode, 9);
    expect(result.single.headers, {'Referer': 'x'});
  });

  test('listSources returns [] on malformed JSON without throwing', () async {
    install((call) async => 'not json');
    final svc = MihonExtensionService();
    final result = await svc.listSources();
    expect(result, isEmpty);
  });

  test('getFilterList invokes "getFilterList" with sourceId and returns the raw JSON',
      () async {
    const fakeJson = '[{"type":"header","name":"Sort"}]';
    install((call) async => call.method == 'getFilterList' ? fakeJson : null);
    final svc = MihonExtensionService();
    final result = await svc.getFilterList(42);

    expect(result, fakeJson);
    expect(log.length, 1);
    expect(log.first.method, 'getFilterList');
    expect((log.first.arguments as Map)['sourceId'], 42);
  });

  test('getFilterList returns null on PlatformException', () async {
    install((call) async {
      throw PlatformException(code: 'NO_FILTERS');
    });
    final svc = MihonExtensionService();
    expect(await svc.getFilterList(42), isNull);
  });

  test('getFilterList returns null when channel is unregistered', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final svc = MihonExtensionService();
    expect(await svc.getFilterList(42), isNull);
  });

  test('hasSourceSettings invokes "hasSourceSettings" with sourceId', () async {
    install((call) async => call.method == 'hasSourceSettings' ? true : null);
    final svc = MihonExtensionService();
    final result = await svc.hasSourceSettings(12345);

    expect(result, isTrue);
    expect(log.length, 1);
    expect(log.first.method, 'hasSourceSettings');
    expect((log.first.arguments as Map)['sourceId'], 12345);
  });

  test('hasSourceSettings returns false on PlatformException', () async {
    install((call) async {
      throw PlatformException(code: 'NOT_FOUND');
    });
    final svc = MihonExtensionService();
    expect(await svc.hasSourceSettings(12345), isFalse);
  });

  test('openSourceSettings invokes "openSourceSettings" with sourceId', () async {
    install((call) async => null);
    final svc = MihonExtensionService();
    await svc.openSourceSettings(99);

    expect(log.length, 1);
    expect(log.first.method, 'openSourceSettings');
    expect((log.first.arguments as Map)['sourceId'], 99);
  });

  test('openSourceSettings swallows PlatformException rather than throwing',
      () async {
    install((call) async {
      throw PlatformException(code: 'NO_SETTINGS');
    });
    final svc = MihonExtensionService();
    // Must not throw.
    await svc.openSourceSettings(99);
  });
}
