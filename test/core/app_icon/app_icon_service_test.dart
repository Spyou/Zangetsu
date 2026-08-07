import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_icon/app_icon_service.dart';

void main() {
  late Directory tmp;
  late AppIconService icons;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('app_icon');
    Hive.init(tmp.path);
    await Hive.openBox(AppIconService.boxName);
    icons = AppIconService();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('AppIconService.selectedId', () {
    test('defaults to the new logo when nothing has been chosen', () {
      expect(icons.selectedId, AppIconService.defaultId);
    });

    test('falls back to the default for an id this build no longer ships',
        () async {
      // A pref written by a build that offered an icon we since removed. The
      // picker must still show a selection rather than nothing.
      await Hive.box(AppIconService.boxName).put('appIconId', 'retired-icon');

      expect(icons.selectedId, AppIconService.defaultId);
    });

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
}
