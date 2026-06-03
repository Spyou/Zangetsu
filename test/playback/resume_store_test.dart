import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/resume_store.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('resume_test');
    Hive.init(tmp.path);
    await ResumeStore.init();
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('save then get round-trips a position', () async {
    final store = ResumeStore();
    await store.save('allanime', 'show-1', 'ep-1', const Duration(seconds: 90), const Duration(minutes: 24));
    final mark = store.get('allanime', 'show-1', 'ep-1');
    expect(mark, isNotNull);
    expect(mark!.position.inSeconds, 90);
    expect(mark.duration.inMinutes, 24);
    expect(mark.finished, false);
  });

  test('get returns null for unknown episode', () {
    expect(ResumeStore().get('allanime', 'show-1', 'nope'), isNull);
  });

  test('same episode id in a different show does not collide', () async {
    final store = ResumeStore();
    await store.save('allanime', 'show-A', 'S1E1', const Duration(seconds: 90), const Duration(minutes: 24));
    // Same source + episode id, different show — must be a separate position.
    expect(store.get('allanime', 'show-B', 'S1E1'), isNull);
    expect(store.get('allanime', 'show-A', 'S1E1')!.position.inSeconds, 90);
  });

  test('finished is true when near the end (>92%)', () async {
    final store = ResumeStore();
    await store.save('allanime', 'show-1', 'ep-2', const Duration(minutes: 23, seconds: 30),
        const Duration(minutes: 24));
    expect(store.get('allanime', 'show-1', 'ep-2')!.finished, true);
  });
}
