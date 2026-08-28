import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/debrid/debrid_prefs.dart';
import 'package:watch_app/core/debrid/debrid_provider.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox(DebridPrefs.boxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('mode defaults to off and round-trips prefer/always', () async {
    final p = DebridPrefs();
    expect(p.mode, DebridMode.off);
    await p.setMode(DebridMode.prefer);
    expect(p.mode, DebridMode.prefer);
    await p.setMode(DebridMode.always);
    expect(p.mode, DebridMode.always);
  });

  test('activeService is null by default and round-trips', () async {
    final p = DebridPrefs();
    expect(p.activeService, isNull);
    await p.setActiveService(DebridService.torbox);
    expect(p.activeService, DebridService.torbox);
    await p.setActiveService(null);
    expect(p.activeService, isNull);
  });
}
