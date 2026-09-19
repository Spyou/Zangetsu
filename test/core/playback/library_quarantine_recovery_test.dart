import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/reading/read_history.dart';

/// A value only an OLD build could read, used to make a box unreadable —
/// exactly the `HiveError: Cannot read, unknown typeId` seen on real devices.
class _Legacy {}

class _LegacyAdapter extends TypeAdapter<_Legacy> {
  @override
  final int typeId = 116;
  @override
  _Legacy read(BinaryReader reader) => _Legacy();
  @override
  void write(BinaryWriter writer, _Legacy obj) {}
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lib_quarantine_test');
    Hive.init(dir.path);
    hiveBoxDir = dir.path;
    quarantinedBoxes.clear();
  });

  tearDown(() async {
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> breakBox(String name) async {
    if (!Hive.isAdapterRegistered(116)) Hive.registerAdapter(_LegacyAdapter());
    final box = await Hive.openBox<Map>(name);
    await box.put('k', {'v': _Legacy()});
    await box.close();
    Hive.resetAdapters(); // this build no longer knows typeId 116
  }

  /// Hive leaves an orphan errored completer behind a failed openBox; swallow
  /// only that, and surface anything real.
  Future<void> initIgnoringOrphanError(Future<void> Function() init) {
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await init();
        done.complete();
      } catch (e, s) {
        done.completeError(e, s);
      }
    }, (_, _) {});
    return done.future.timeout(const Duration(seconds: 10));
  }

  Future<void> seedThrottle(String key) async {
    final meta = await Hive.openBox(MyListStore.syncMetaBox);
    await meta.put(key, DateTime.now().millisecondsSinceEpoch);
  }

  test('a quarantined My List clears the pull throttle so cloud can restore it',
      () async {
    await breakBox(MyListStore.boxName);
    await seedThrottle('mylist_lastPullMs');

    await initIgnoringOrphanError(MyListStore.init);

    expect(quarantinedBoxes, contains(MyListStore.boxName));
    // Without this the next launch reads a fresh timestamp, skips the pull,
    // and the user stares at an empty list for 12 hours.
    expect(
      Hive.box(MyListStore.syncMetaBox).get('mylist_lastPullMs'),
      isNull,
    );
  });

  test('a quarantined history clears its own pull throttle', () async {
    await breakBox(WatchHistory.boxName);
    await seedThrottle('history_lastPullMs');

    await initIgnoringOrphanError(WatchHistory.init);

    expect(quarantinedBoxes, contains(WatchHistory.boxName));
    expect(
      Hive.box(WatchHistory.syncMetaBox).get('history_lastPullMs'),
      isNull,
    );
  });

  test('a quarantined reading history clears its own pull throttle', () async {
    await breakBox(ReadHistory.boxName);
    await seedThrottle('reading_history_lastPullMs');

    await initIgnoringOrphanError(ReadHistory.init);

    expect(quarantinedBoxes, contains(ReadHistory.boxName));
    expect(
      Hive.box(ReadHistory.syncMetaBox).get('reading_history_lastPullMs'),
      isNull,
    );
  });

  test('a healthy My List leaves the throttle alone', () async {
    await seedThrottle('mylist_lastPullMs');

    await MyListStore.init();

    expect(quarantinedBoxes, isEmpty);
    expect(
      Hive.box(MyListStore.syncMetaBox).get('mylist_lastPullMs'),
      isNotNull, // a normal launch must still be throttled
    );
  });
}
