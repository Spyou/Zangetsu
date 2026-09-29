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
    await Hive.openBox<Map>('watch_history');
    await Hive.openBox<Map>('read_history');
    await Hive.openBox<Map>('read_positions');
    await Hive.openBox('list_status'); // untyped, matches ListStatusStore
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('build then merge: My List union + watch history keep-newer', () async {
    Hive.box<Map>('my_list').put('src::1',
        {'id': '1', 'sourceId': 'src', 'title': 'A', 'url': 'u1', 'type': 'anime'});
    Hive.box<Map>('watch_history').put('src::1',
        {'sourceId': 'src', 'showId': '1', 'positionMs': 100, 'updatedAt': 100});
    final data = LibraryBackup().build();

    await Hive.box<Map>('my_list').clear();
    await Hive.box<Map>('watch_history').clear();
    // a NEWER local history entry must survive the merge
    Hive.box<Map>('watch_history').put('src::1',
        {'sourceId': 'src', 'showId': '1', 'positionMs': 500, 'updatedAt': 500});

    await LibraryBackup().merge(data);

    expect(Hive.box<Map>('my_list').containsKey('src::1'), isTrue); // union restored
    expect(Hive.box<Map>('watch_history').get('src::1')!['updatedAt'], 500); // newer kept
  });

  test('build then merge: manga/novel reading progress round-trips', () async {
    Hive.box<Map>('read_history').put('mihon:src::1', {
      'sourceId': 'mihon:src',
      'showId': '1',
      'title': 'Manga A',
      'chapterId': 'c1',
      'pos': 3,
      'total': 20,
      'updatedMs': 1000,
      'type': 'manga',
    });
    Hive.box<Map>('read_positions').put(
        'mihon:src::1::c1', {'pos': 3, 'total': 20});
    Hive.box('list_status').put('mihon:src::1', 'reading');

    final data = LibraryBackup().build();

    await Hive.box<Map>('read_history').clear();
    await Hive.box<Map>('read_positions').clear();
    await Hive.box('list_status').clear();

    await LibraryBackup().merge(data);

    expect(Hive.box<Map>('read_history').containsKey('mihon:src::1'), isTrue);
    expect(Hive.box<Map>('read_history').get('mihon:src::1')!['title'],
        'Manga A');
    expect(Hive.box<Map>('read_positions').get('mihon:src::1::c1'),
        {'pos': 3, 'total': 20});
    expect(Hive.box('list_status').get('mihon:src::1'), 'reading');
  });

  test('merge: reading progress is union — existing entries win, nothing is clobbered',
      () async {
    Hive.box('list_status').put('src::1', 'completed'); // current session's data
    await LibraryBackup().merge({
      'listStatus': {'src::1': 'dropped', 'src::2': 'reading'},
    });

    // pre-existing entry survives untouched...
    expect(Hive.box('list_status').get('src::1'), 'completed');
    // ...but a genuinely new key is still added.
    expect(Hive.box('list_status').get('src::2'), 'reading');
  });

  test('merge: an OLD backup missing the new reading keys imports fine', () async {
    // Shape of a backup taken before manga/novel support existed.
    await LibraryBackup().merge({
      'myList': [
        {'id': '1', 'sourceId': 's'},
      ],
      'history': [],
    });

    expect(Hive.box<Map>('my_list').containsKey('s::1'), isTrue);
    expect(Hive.box<Map>('read_history').isEmpty, isTrue);
    expect(Hive.box<Map>('read_positions').isEmpty, isTrue);
    expect(Hive.box('list_status').isEmpty, isTrue);
  });

  test('merge is a no-op when a box is closed', () async {
    await Hive.box<Map>('my_list').close();
    await Hive.box<Map>('read_history').close();
    await LibraryBackup().merge({
      'myList': [{'id': '1', 'sourceId': 's'}],
      'history': [],
      'readHistory': {'k': {'a': 1}},
    });
  });
}
