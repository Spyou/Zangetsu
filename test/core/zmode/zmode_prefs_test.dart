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

  test('is off by default and follows anime', () {
    expect(ZModePrefs.enabled, isFalse);
    expect(ZModePrefs.streamKind, StreamKind.anime);
  });

  test('persists the toggle and bumps revision', () async {
    final before = ZModePrefs.revision.value;
    await ZModePrefs.setEnabled(true);
    expect(ZModePrefs.enabled, isTrue);
    expect(ZModePrefs.revision.value, before + 1);
    await Hive.close();
    Hive.init(dir.path);
    await ZModePrefs.init();
    expect(ZModePrefs.enabled, isTrue);
  });

  test('persists streamKind', () async {
    await ZModePrefs.setStreamKind(StreamKind.movie);
    expect(ZModePrefs.streamKind, StreamKind.movie);
  });

  test('sourcesMode is off by default, round-trips and bumps revision', () async {
    expect(ZModePrefs.sourcesMode, isFalse);
    final before = ZModePrefs.revision.value;
    await ZModePrefs.setSourcesMode(true);
    expect(ZModePrefs.sourcesMode, isTrue);
    expect(ZModePrefs.revision.value, before + 1);
    await Hive.close();
    Hive.init(dir.path);
    await ZModePrefs.init();
    expect(ZModePrefs.sourcesMode, isTrue);
  });

  test('setting sourcesMode to the same value does not bump revision', () async {
    await ZModePrefs.setSourcesMode(true);
    final before = ZModePrefs.revision.value;
    await ZModePrefs.setSourcesMode(true);
    expect(ZModePrefs.revision.value, before);
  });

  test('reads as off before init without throwing', () async {
    await Hive.close();
    Hive.init(dir.path);
    expect(ZModePrefs.enabled, isFalse);
    expect(ZModePrefs.sourcesMode, isFalse);
  });
}
