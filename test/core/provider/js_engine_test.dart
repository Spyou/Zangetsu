import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/error/exceptions.dart';
import 'package:watch_app/core/provider/js_engine.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

/// The runtime moved off the UI isolate on Android (see [JsEngine]). These
/// pin the seam that move went through: `load` became async, and it still has
/// to fail the same way it always did, because ProviderRegistry.loadAll
/// decides whether a source is usable by whether this throws.
///
/// Under `flutter test` the engine is always the in-process one — the isolate
/// path needs a real device and is verified there.
void main() {
  // getJavascriptRuntime()'s enableFetch reads a JS asset through rootBundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderManager manager;

  setUp(() => manager = ProviderManager(dio: Dio()));
  tearDown(() => manager.disposeAll());

  test('a provider that evaluates cleanly loads and is registered', () async {
    await manager.load(
      sourceId: 'ok',
      jsSource: 'function getInfo() { return { name: "ok" }; }',
    );
    expect(manager.get('ok'), isNotNull);
    expect(manager.installedIds, contains('ok'));
  });

  test('a provider whose JS does not parse throws, and stays unregistered',
      () async {
    // The shape that matters: loadAll() catches this per entry and marks the
    // source skipped. If it stopped throwing, a broken source would look
    // installed and fail one confusing call at a time instead.
    await expectLater(
      manager.load(sourceId: 'bad', jsSource: 'function ( { syntax error'),
      throwsA(isA<JsRuntimeException>()),
    );
    expect(manager.get('bad'), isNull);
  });

  test('an extractor that does not parse throws too', () async {
    await expectLater(
      manager.loadExtractor(extractorId: 'bad', jsSource: 'var = ;'),
      throwsA(isA<JsRuntimeException>()),
    );
  });

  test('setSettings never throws, even for a source that was never loaded',
      () async {
    // Best-effort by contract — it is called on every settings change and
    // must not be able to take a screen down.
    expect(() => manager.setSettings('nobody', {'a': 1}), returnsNormally);
  });

  test('a loaded provider can be removed and stops being registered', () async {
    await manager.load(
      sourceId: 'gone',
      jsSource: 'function getInfo() { return {}; }',
    );
    expect(manager.get('gone'), isNotNull);
    manager.remove('gone');
    expect(manager.get('gone'), isNull);
  });
}
