import 'dart:io';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/library_backup.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    Hive.init(dir.path);
    await Hive.openBox<Map>('my_list');
    await Hive.openBox<Map>('history');
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('build then merge: My List union + history keep-newer', () async {
    Hive.box<Map>('my_list').put('src::1',
        {'id': '1', 'sourceId': 'src', 'title': 'A', 'url': 'u1', 'type': 'anime'});
    Hive.box<Map>('history').put('src::1',
        {'sourceId': 'src', 'showId': '1', 'positionMs': 100, 'updatedAt': 100});
    final data = LibraryBackup().build();

    await Hive.box<Map>('my_list').clear();
    await Hive.box<Map>('history').clear();
    // a NEWER local history entry must survive the merge
    Hive.box<Map>('history').put('src::1',
        {'sourceId': 'src', 'showId': '1', 'positionMs': 500, 'updatedAt': 500});

    await LibraryBackup().merge(data);

    expect(Hive.box<Map>('my_list').containsKey('src::1'), isTrue); // union restored
    expect(Hive.box<Map>('history').get('src::1')!['updatedAt'], 500); // newer kept
  });

  test('merge is a no-op when a box is closed', () async {
    await Hive.box<Map>('my_list').close();
    await LibraryBackup().merge({'myList': [{'id': '1', 'sourceId': 's'}], 'history': []});
  });
}
