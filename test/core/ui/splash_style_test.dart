import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/ui/splash_style.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('splash_style');
    Hive.init(tmp.path);
    await Hive.openBox(SplashStyle.boxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('an untouched install still gets the wordmark', () {
    // The whole point of the default: adding this feature must not change what
    // an existing user sees at launch.
    expect(SplashStyle.selectedId, 'wordmark');
    expect(SplashStyle.defaultId, 'wordmark');
  });

  test('a choice is remembered', () async {
    await SplashStyle.select('bankai');
    expect(SplashStyle.selectedId, 'bankai');
  });

  test('an id this build no longer ships falls back to the default', () async {
    Hive.box(SplashStyle.boxName).put('splashStyleId', 'some-old-style');
    expect(SplashStyle.selectedId, 'wordmark');
  });

  test('a non-string value falls back rather than throwing', () {
    Hive.box(SplashStyle.boxName).put('splashStyleId', 42);
    expect(SplashStyle.selectedId, 'wordmark');
  });

  test('an unknown id is refused, not stored', () async {
    await SplashStyle.select('bankai');
    await SplashStyle.select('nonsense');
    expect(SplashStyle.selectedId, 'bankai');
  });

  test('the default option exists and leads the list', () {
    expect(SplashStyle.options.first.id, SplashStyle.defaultId);
  });

  test('ids are unique — they key the stored preference', () {
    final ids = SplashStyle.options.map((o) => o.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  group('read before the box is open', () {
    // The splash is on screen WHILE initDependencies() is still opening boxes,
    // so this is genuinely read against a closed box. Hive.box() throws there,
    // and a throw inside the splash's build is a blank screen on every single
    // cold start — which is exactly what shipped before this guard existed.
    test('falls back to the default instead of throwing', () async {
      await Hive.close();
      expect(() => SplashStyle.selectedId, returnsNormally);
      expect(SplashStyle.selectedId, SplashStyle.defaultId);
    });

    test('a write against a closed box is a no-op, not a crash', () async {
      await Hive.close();
      await expectLater(SplashStyle.select('bankai'), completes);
    });
  });
}
