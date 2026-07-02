import 'dart:io';

import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox(TorrentPrefs.boxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('allowMobileData defaults to false, round-trips true then false',
      () async {
    final p = TorrentPrefs();
    expect(p.allowMobileData, isFalse);
    await p.setAllowMobileData(true);
    expect(p.allowMobileData, isTrue);
    await p.setAllowMobileData(false);
    expect(p.allowMobileData, isFalse);
  });
}
