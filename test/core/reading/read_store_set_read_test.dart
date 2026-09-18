import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/read_store.dart';

/// Marking a chapter read by hand, from the chapter list's long-press menu.

void main() {
  late Directory dir;
  late ReadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('read_store_mark');
    Hive.init(dir.path);
    await ReadStore.init();
    store = ReadStore();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('a chapter you never opened can be marked read', () {
    expect(store.finished('s', 'show', 'c1'), isFalse);
  });

  test('marking read does NOT fake a read position', () async {
    // Writing pos == total would read as finished, but would also send you to
    // the last page next time you opened a chapter you never actually read.
    await store.setRead('s', 'show', 'c1', read: true);

    expect(store.finished('s', 'show', 'c1'), isTrue);
    expect(store.get('s', 'show', 'c1')?.pos ?? 0, 0);
  });

  test('unmarking a chapter you really did read sticks', () async {
    // The 95% rule would still call this finished, so unmarking has to clear
    // the position as well as the flag — otherwise the row springs back.
    await store.save('s', 'show', 'c2', pos: 1000, total: 1000);
    expect(store.finished('s', 'show', 'c2'), isTrue);

    await store.setRead('s', 'show', 'c2', read: false);
    expect(store.finished('s', 'show', 'c2'), isFalse);
  });

  test('marking read leaves other chapters alone', () async {
    await store.setRead('s', 'show', 'c1', read: true);
    expect(store.finished('s', 'show', 'c2'), isFalse);
  });

  test('a real read position still counts without the flag', () async {
    await store.save('s', 'show', 'c3', pos: 960, total: 1000);
    expect(store.finished('s', 'show', 'c3'), isTrue);
  });

  test('reading on after marking read does NOT un-mark it', () async {
    // save() replaces the record, so a hand-set flag has to be carried over —
    // otherwise marking a chapter read and then scrolling one pixel silently
    // undid it on the very next autosave.
    await store.setRead('s', 'show', 'c4', read: true);
    expect(store.finished('s', 'show', 'c4'), isTrue);

    await store.save('s', 'show', 'c4', pos: 3, total: 100);

    expect(store.finished('s', 'show', 'c4'), isTrue,
        reason: 'still read after an autosave from page 3');
    expect(store.get('s', 'show', 'c4')?.pos, 3,
        reason: 'and the real position is still tracked');
  });

  test('unmarking then reading on behaves normally', () async {
    await store.setRead('s', 'show', 'c5', read: true);
    await store.setRead('s', 'show', 'c5', read: false);

    await store.save('s', 'show', 'c5', pos: 10, total: 100);
    expect(store.finished('s', 'show', 'c5'), isFalse);

    await store.save('s', 'show', 'c5', pos: 99, total: 100);
    expect(store.finished('s', 'show', 'c5'), isTrue,
        reason: 'the 95% rule takes over once the flag is gone');
  });
}
