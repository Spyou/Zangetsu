import 'dart:io';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/library_backup.dart';
import 'package:watch_app/core/hive/hive_key.dart';

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

  test('merge hashes oversized keys the same way the stores do', () async {
    // A source URL carrying a multi-kilobyte ?data={…} blob — the exact
    // scenario hiveKey() was introduced for. Without hiveKey() in merge(),
    // the raw >255-byte key would (a) miss the hashed entry already in the
    // box, and (b) be written as-is, corrupting the Hive file.
    final longUrl = 'https://example.test/e?data=${'x' * 600}';
    final hashedKey = hiveKey('src::$longUrl');

    // ── My List: write the way MyList._key does (hashed) ──
    await Hive.box<Map>('my_list').put(hashedKey, {
      'id': longUrl,
      'sourceId': 'src',
      'title': 'Big URL show',
    });

    // ── Watch History: write the way WatchHistory._key does (hashed) ──
    await Hive.box<Map>('watch_history').put(hashedKey, {
      'sourceId': 'src',
      'showId': longUrl,
      'positionMs': 42000,
      'updatedAt': 100,
    });

    // Build a backup whose payload carries the FIELD values (not the keys).
    // A real backup is built from _dump which iterates .values, so the
    // payload has sourceId + id / showId as plain fields — merge() must
    // rebuild the key through hiveKey() to match what the stores wrote.
    final backup = {
      'myList': [
        {'id': longUrl, 'sourceId': 'src', 'title': 'Big URL show'},
      ],
      'history': [
        {
          'sourceId': 'src',
          'showId': longUrl,
          'positionMs': 99000,
          'updatedAt': 200,
        },
      ],
    };

    // Clear and re-merge — the My List union check and the Watch History
    // keep-newer lookup must both find the existing row by its hashed key.
    await Hive.box<Map>('my_list').clear();
    await Hive.box<Map>('watch_history').clear();

    // Seed a NEWER local history entry so keep-newer has something to keep.
    await Hive.box<Map>('watch_history').put(hashedKey, {
      'sourceId': 'src',
      'showId': longUrl,
      'positionMs': 55000,
      'updatedAt': 500,
    });

    await LibraryBackup().merge(backup);

    // My List: the entry should land under the hashed key, not a raw one.
    expect(Hive.box<Map>('my_list').containsKey(hashedKey), isTrue,
        reason: 'My List entry should be stored under the hashed key');
    expect(Hive.box<Map>('my_list').length, 1,
        reason: 'no duplicate under a raw key');

    // Watch History: the newer local entry must survive the merge.
    expect(Hive.box<Map>('watch_history').get(hashedKey)!['updatedAt'], 500,
        reason: 'keep-newer must find the existing row by hashed key');
    expect(Hive.box<Map>('watch_history').length, 1,
        reason: 'no duplicate under a raw key');
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
