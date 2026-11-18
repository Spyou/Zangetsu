import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  test('fresh Android phone box migrates to the native player', () {
    expect(
      resolveDefaultPlayerPackage(
        isAndroidPhone: true,
        hasStoredChoice: false,
        alreadyMigrated: false,
      ),
      PlaybackPrefs.androidPlayerId,
    );
  });

  test('explicit mpv pick (stored empty choice) is left alone', () {
    expect(
      resolveDefaultPlayerPackage(
        isAndroidPhone: true,
        hasStoredChoice: true,
        alreadyMigrated: false,
      ),
      isNull,
    );
  });

  test('already-migrated box is a no-op', () {
    expect(
      resolveDefaultPlayerPackage(
        isAndroidPhone: true,
        hasStoredChoice: false,
        alreadyMigrated: true,
      ),
      isNull,
    );
  });

  test('non-Android and TV boxes are left alone', () {
    expect(
      resolveDefaultPlayerPackage(
        isAndroidPhone: false,
        hasStoredChoice: false,
        alreadyMigrated: false,
      ),
      isNull,
    );
  });

  test('init alone flips nothing; the injector owns the one-time stamp', () async {
    final dir = await Directory.systemTemp.createTemp('exo_default_migrate');
    Hive.init(dir.path);
    try {
      final box = await Hive.openBox<dynamic>(PlaybackPrefs.boxName);
      expect(box.containsKey('externalPlayerPackage'), isFalse);
      await PlaybackPrefs.init();
      // Migration + flag live in the injector, not init(): nothing stamped,
      // nothing flipped. Test host is not Android anyway.
      expect(box.containsKey('playerEngineMigrated'), isFalse);
      expect(box.containsKey('externalPlayerPackage'), isFalse);
    } finally {
      await Hive.close();
      await dir.delete(recursive: true);
    }
  });
}
