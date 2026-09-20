import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_icon/app_icon_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppIconService icons;

  /// What the stand-in PackageManager reports as actually enabled. Null means
  /// the native side is unreadable (the channel throws).
  String? nativeAlias;

  /// Installed once in setUp so `select()` can reach the channel too — its
  /// 'set' call would otherwise throw MissingPluginException.
  void installNativeStub() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('zangetsu/app_icon'), (
          call,
        ) async {
          if (call.method != 'current') return null;
          if (nativeAlias == null) throw PlatformException(code: 'unavailable');
          return nativeAlias;
        });
  }

  void nativeSays(String? alias) => nativeAlias = alias;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('app_icon');
    Hive.init(tmp.path);
    await Hive.openBox(AppIconService.boxName);
    AppIconService.isSupported = () => true; // reach the Android-only paths
    nativeAlias = null;
    installNativeStub();
    icons = AppIconService();
  });

  tearDown(() async {
    AppIconService.resetSupportedForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('zangetsu/app_icon'),
          null,
        );
    await Hive.deleteFromDisk();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('AppIconService.selectedId', () {
    test('defaults to the new logo when nothing has been chosen', () {
      expect(icons.selectedId, AppIconService.defaultId);
    });

    test(
      'falls back to the default for an id this build no longer ships',
      () async {
        // A pref written by a build that offered an icon we since removed. The
        // picker must still show a selection rather than nothing.
        await Hive.box(AppIconService.boxName).put('appIconId', 'retired-icon');

        expect(icons.selectedId, AppIconService.defaultId);
      },
    );

    test('falls back to the default for a non-string value', () async {
      await Hive.box(AppIconService.boxName).put('appIconId', 42);

      expect(icons.selectedId, AppIconService.defaultId);
    });
  });

  group('options', () {
    test('the default option exists and leads the list', () {
      expect(AppIconService.options.first.id, AppIconService.defaultId);
    });

    test('ids are unique — they key the native aliases', () {
      final ids = AppIconService.options.map((o) => o.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every option ships a preview asset', () {
      for (final o in AppIconService.options) {
        expect(
          File(o.asset).existsSync(),
          isTrue,
          reason: '${o.id} points at a missing preview: ${o.asset}',
        );
      }
    });
  });

  group('reconciledId — Settings must show what the launcher shows', () {
    test(
      'a stale pref is corrected to the alias Android has enabled',
      () async {
        // The exact reported bug: an update changed which alias ships enabled,
        // so the pref still said 'classic' while the crescent was on screen.
        await icons.select('classic');
        nativeSays('crescent');
        expect(await icons.reconciledId(), 'crescent');
        expect(
          icons.selectedId,
          'crescent',
          reason: 'the pref is rewritten too',
        );
      },
    );

    test('an agreeing pref is left alone', () async {
      await icons.select('classic');
      nativeSays('classic');
      expect(await icons.reconciledId(), 'classic');
      expect(icons.selectedId, 'classic');
    });

    test('an unreadable native side never clobbers a good pref', () async {
      await icons.select('classic');
      nativeSays(null);
      expect(await icons.reconciledId(), 'classic');
      expect(icons.selectedId, 'classic');
    });

    test('an alias this build does not ship is ignored', () async {
      await icons.select('classic');
      nativeSays('some-removed-icon');
      expect(await icons.reconciledId(), 'classic');
      expect(icons.selectedId, 'classic');
    });
  });
}
