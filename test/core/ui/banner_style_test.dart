import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/ui/banner_style.dart';

/// The whole point of this pref is that picking nothing changes nothing: every
/// install that never opens the picker must keep the banner it already has.
/// These pin that, and the fallbacks that protect it.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('banner_style');
    Hive.init(tmp.path);
    await Hive.openBox(BannerStyle.boxName);
    BannerStyle.current.value = BannerStyle.defaultId;
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('what an untouched install gets', () {
    test('the banner it already had', () {
      expect(BannerStyle.selectedId, BannerStyle.defaultId);
      expect(BannerStyle.defaultId, 'card');
    });

    test('the default is the first option, so the picker leads with it', () {
      expect(BannerStyle.options.first.id, BannerStyle.defaultId);
    });
  });

  group('reading never leaves Home with nothing to draw', () {
    test('an id this build has never heard of falls back', () async {
      // A newer build could ship a fourth style; going back to this one must
      // not blank the banner.
      await Hive.box(BannerStyle.boxName).put('homeBannerStyle', 'spiral');
      expect(BannerStyle.selectedId, BannerStyle.defaultId);
    });

    test('a non-string value falls back', () async {
      await Hive.box(BannerStyle.boxName).put('homeBannerStyle', 7);
      expect(BannerStyle.selectedId, BannerStyle.defaultId);
    });

    test('a closed box falls back instead of throwing', () async {
      await Hive.box(BannerStyle.boxName).close();
      expect(BannerStyle.selectedId, BannerStyle.defaultId);
    });
  });

  group('picking one', () {
    test('persists and tells Home in the same breath', () async {
      await BannerStyle.select(BannerStyle.panelsId);
      expect(BannerStyle.selectedId, BannerStyle.panelsId);
      expect(BannerStyle.current.value, BannerStyle.panelsId);
    });

    test('an unknown id is refused, not written', () async {
      await BannerStyle.select(BannerStyle.panelsId);
      await BannerStyle.select('moon'); // a style that was cut before shipping
      await BannerStyle.select('nonsense');
      expect(BannerStyle.selectedId, BannerStyle.panelsId);
      expect(BannerStyle.current.value, BannerStyle.panelsId);
    });

    test('every shipped id round-trips', () async {
      for (final o in BannerStyle.options) {
        await BannerStyle.select(o.id);
        expect(BannerStyle.selectedId, o.id, reason: o.id);
      }
    });

    test('writing with the box closed is a no-op, not a crash', () async {
      await Hive.box(BannerStyle.boxName).close();
      await BannerStyle.select(BannerStyle.panelsId);
      expect(BannerStyle.selectedId, BannerStyle.defaultId);
    });
  });

  test('ids are unique — two options sharing one would make the pref lie', () {
    final ids = BannerStyle.options.map((o) => o.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}
