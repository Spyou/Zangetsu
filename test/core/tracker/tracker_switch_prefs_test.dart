import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/tracker/tracker_switch_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tracker_switch_prefs');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('selection is optional before storage is initialized', () async {
    expect(TrackerSwitchPrefs.lastTracker(), isNull);
    await TrackerSwitchPrefs.saveLastTracker('AniList');
    expect(TrackerSwitchPrefs.lastTracker(), isNull);
  });

  test(
    'selection survives reopening and choosing Zangetsu List clears it',
    () async {
      await TrackerSwitchPrefs.init();
      await TrackerSwitchPrefs.saveLastTracker('AniList');
      await Hive.close();
      await TrackerSwitchPrefs.init();
      expect(TrackerSwitchPrefs.lastTracker(), 'AniList');
      await TrackerSwitchPrefs.saveLastTracker(null);
      await Hive.close();
      await TrackerSwitchPrefs.init();
      expect(TrackerSwitchPrefs.lastTracker(), isNull);
    },
  );

  test('malformed saved selection falls back to the own list', () async {
    await TrackerSwitchPrefs.init();
    await Hive.box(TrackerSwitchPrefs.boxName).put('lastTracker', 42);
    expect(TrackerSwitchPrefs.lastTracker(), isNull);
  });
}
