import 'dart:io';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/settings_backup.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox('playback_prefs');
    // A typed Box<Map> — the codec must read/write it without a type-mismatch.
    await Hive.openBox<Map>('title_prefs');
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('build dumps open boxes and merge overwrites them', () async {
    Hive.box('playback_prefs').put('defaultSpeed', 1.5);
    final data = SettingsBackup().build();
    await Hive.box('playback_prefs').clear();
    await SettingsBackup().merge(data);
    expect(Hive.box('playback_prefs').get('defaultSpeed'), 1.5);
  });

  test('merge skips boxes that are not open (no throw)', () async {
    await SettingsBackup().merge({'not_open_box': {'x': 1}});
  });

  // Regression: title_prefs is opened as Box<Map>; an untyped Hive.box() throws.
  test('handles a Box<Map>-typed box without a type mismatch', () async {
    Hive.box<Map>('title_prefs').put('src::1', {'quality': '720p'});
    final data = SettingsBackup().build(); // must NOT throw
    expect(data['title_prefs'], {
      'src::1': {'quality': '720p'},
    });
    await Hive.box<Map>('title_prefs').clear();
    await SettingsBackup().merge(data);
    expect(Hive.box<Map>('title_prefs').get('src::1'), {'quality': '720p'});
  });
}
