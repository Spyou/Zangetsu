import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/watch_history.dart';

// Null service + logged-out callback → save() never touches the network (cloud
// push is skipped when the user id is null), so these stay pure local-Hive
// tests.
WatchHistory _store() => WatchHistory(null, () => null);

void main() {
  late Directory dir;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('wh_test');
    Hive.init(dir.path);
    await Hive.deleteBoxFromDisk(WatchHistory.boxName); // clean slate
    await WatchHistory.init();
  });
  tearDown(() async {
    await Hive.box<Map>(WatchHistory.boxName).clear();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  HistoryEntry mk(String show, int updatedAt, {int pos = 60000, int dur = 1200000}) => HistoryEntry(
    sourceId: 'allanime', showId: show, showTitle: 'Show $show', showUrl: show,
    category: 'sub', episodeId: 'sub:1', episodeNumber: 1, episodeUrl: 'allanime://$show/sub/1',
    position: Duration(milliseconds: pos), duration: Duration(milliseconds: dur), updatedAt: updatedAt);

  test('recent() is newest-first', () async {
    final wh = _store();
    await wh.save(mk('a', 100));
    await wh.save(mk('b', 300));
    await wh.save(mk('c', 200));
    final r = wh.recent();
    expect(r.map((e) => e.showId).toList(), ['b', 'c', 'a']);
  });

  test('recent() excludes finished (>=92%)', () async {
    final wh = _store();
    await wh.save(mk('a', 100));
    await wh.save(mk('done', 200, pos: 1190000, dur: 1200000)); // ~99% -> finished
    final r = wh.recent();
    expect(r.map((e) => e.showId), contains('a'));
    expect(r.map((e) => e.showId), isNot(contains('done')));
  });
}
