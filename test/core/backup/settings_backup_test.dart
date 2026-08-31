import 'dart:io';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/settings_backup.dart';

void main() {
  _driftGuard();
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

// The real bug wasn't any one missing box — it was drift. The list was written
// once and never revisited, so every settings box added afterwards silently
// fell out of backup (nav_prefs was missing the same day it was created).
// This fails when a new `boxName` appears in lib/ and nobody has decided
// whether it belongs in a backup.
void _driftGuard() {
  group('settings backup coverage', () {
    /// Boxes deliberately left out, each with the reason it must stay out.
    /// Adding one here is a decision; leaving a box in neither list is a bug.
    const excluded = <String, String>{
      // Secrets / tokens — must never leave the device in a backup file.
      'anilist': 'oauth token',
      'mal': 'oauth token',
      'simkl': 'oauth token',
      'discord': 'rpc token',
      'auth_cache': 'session cache',
      // Device-specific: holds a SAF content:// URI that is meaningless (and
      // unwritable) on another device.
      'download_prefs': 'device-specific download location',
      // Reference source ids the restoring device may not have installed.
      'pinned_sources': 'source ids',
      'subscriptions': 'source ids',
      // Installed sources — carried by the separate Sources bundle.
      'provider_settings': 'sources bundle',
      'provider_registry': 'sources bundle',
      'provider_repos': 'sources bundle',
      'cs_repos': 'sources bundle',
      'aniyomi_installed': 'sources bundle',
      'lnreader_plugins': 'sources bundle',
      // User data — carried by the library backup, not settings.
      'my_list': 'library backup',
      'watch_history': 'library backup',
      'read_history': 'library backup',
      'resume_positions': 'library backup',
      'read_positions': 'library backup',
      'list_status': 'library backup',
      'list_categories': 'library backup',
      'tracker_bindings': 'library backup',
      'reader_overrides': 'per-title, library-shaped',
      'chapter_downloads': 'downloads, not settings',
      'downloads': 'downloads, not settings',
      // Caches and transient state — regenerated, never restored.
      'logo_cache': 'cache',
      'provider_js_cache': 'cache',
      'episode_meta': 'cache',
      'cf_clearance': 'cache',
      'source_health': 'transient',
      'updates': 'transient',
      'announcements': 'transient',
      'search_history': 'transient',
      'content_mode': 'restored per device',
    };

    test('every settings box is either backed up or explicitly excluded', () {
      final declared = <String>{};
      final re = RegExp(r"boxName\s*=\s*'([a-z0-9_]+)'");
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final m in re.allMatches(f.readAsStringSync())) {
          declared.add(m.group(1)!);
        }
      }
      expect(declared, isNotEmpty, reason: 'the scan itself must find boxes');

      final unclassified = declared
          .where((b) => !SettingsBackup.boxNames.contains(b))
          .where((b) => !excluded.containsKey(b))
          .toList()
        ..sort();

      expect(
        unclassified,
        isEmpty,
        reason: 'These Hive boxes are neither backed up nor listed as excluded.\n'
            'Add each to SettingsBackup.boxNames if it holds user settings, or\n'
            'to this test\'s `excluded` map with the reason it should not be\n'
            'restored: $unclassified',
      );
    });

    test('no backed-up box is also on the excluded list', () {
      for (final b in SettingsBackup.boxNames) {
        expect(excluded.containsKey(b), isFalse, reason: '$b is in both lists');
      }
    });
  });
}
