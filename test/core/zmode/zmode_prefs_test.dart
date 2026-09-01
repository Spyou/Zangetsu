import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zmode_prefs');
    Hive.init(dir.path);
    await ZModePrefs.init();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  // On for everyone since the Settings toggle was removed: the metadata
  // catalogue is how the app browses now, so a fresh box must land there
  // rather than on the source-only path nothing can switch back to.
  test('is on by default and follows anime', () {
    expect(ZModePrefs.enabled, isTrue);
    expect(ZModePrefs.streamKind, StreamKind.anime);
  });

  test('persists the toggle and bumps revision', () async {
    final before = ZModePrefs.revision.value;
    // Off is now the value that differs from the default, so that is the one
    // worth writing. The path still exists for tests even though no UI
    // reaches it.
    await ZModePrefs.setEnabled(false);
    expect(ZModePrefs.enabled, isFalse);
    expect(ZModePrefs.revision.value, before + 1);
    await Hive.close();
    Hive.init(dir.path);
    await ZModePrefs.init();
    // Survives a restart: the stored false must win over the on-by-default,
    // or the write did nothing.
    expect(ZModePrefs.enabled, isFalse);
  });

  test('persists streamKind', () async {
    await ZModePrefs.setStreamKind(StreamKind.movie);
    expect(ZModePrefs.streamKind, StreamKind.movie);
  });

  // The splash reads this before Hive is up. It must give the same answer the
  // opened box would, or the app would start on one path and switch to the
  // other a moment later.
  test('reads as the default before init without throwing', () async {
    await Hive.close();
    Hive.init(dir.path);
    expect(ZModePrefs.enabled, isTrue);
  });
}
