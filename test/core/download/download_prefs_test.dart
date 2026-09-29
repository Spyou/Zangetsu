import 'dart:io';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox(DownloadPrefs.boxName);
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('defaults to null, round-trips a set, and clears', () async {
    final p = DownloadPrefs();
    expect(p.locationUri, isNull);
    expect(p.locationLabel, isNull);
    await p.setLocation('content://tree/primary%3ADownloads/x', 'Movies');
    expect(p.locationUri, 'content://tree/primary%3ADownloads/x');
    expect(p.locationLabel, 'Movies');
    await p.setLocation(null, null);
    expect(p.locationUri, isNull);
    expect(p.locationLabel, isNull);
  });

  test('isUriPath detects content:// paths only', () {
    expect(isUriPath('content://tree/x/doc/y'), isTrue);
    expect(isUriPath('/storage/emulated/0/Download/x.mp4'), isFalse);
  });
}
