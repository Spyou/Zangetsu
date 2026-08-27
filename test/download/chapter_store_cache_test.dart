import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/mode/content_mode.dart';

void main() {
  late Directory dir;
  late ChapterDownloadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chapter_store_perf');
    Hive.init(dir.path);
    await ChapterDownloadStore.init();
    store = ChapterDownloadStore();
    await store.putAll([
      for (var i = 0; i < 4000; i++)
        ChapterDownload(
          id: ChapterDownload.idFor('src', 'https://x/c$i'),
          sourceId: 'src',
          showId: 'show',
          showTitle: 'Show',
          chapterId: 'c$i',
          chapterUrl: 'https://x/c$i',
          chapterTitle: 'Chapter $i',
          mode: i.isEven ? ContentMode.manga : ContentMode.novel,
          status: ChapterDownloadStatus.done,
          createdAt: i,
        ),
    ]);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChapterDownloadStore.boxName);
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('repeat all() calls are served from cache', () {
    final first = Stopwatch()..start();
    store.all();
    first.stop();
    final second = Stopwatch()..start();
    for (var i = 0; i < 50; i++) {
      store.all();
    }
    second.stop();
    print('  cold all(): ${first.elapsedMicroseconds}us');
    print('  50x cached: ${second.elapsedMicroseconds}us');
    // 50 cached reads must cost less than one cold parse.
    expect(second.elapsedMicroseconds, lessThan(first.elapsedMicroseconds));
  });

  test('countDone is cheaper than parsing everything', () {
    store.invalidateCache();
    final parse = Stopwatch()..start();
    store.all().where((c) => c.mode == ContentMode.manga).length;
    parse.stop();
    store.invalidateCache();
    final count = Stopwatch()..start();
    store.countDone(ContentMode.manga);
    count.stop();
    print('  parse+filter: ${parse.elapsedMicroseconds}us');
    print('  countDone   : ${count.elapsedMicroseconds}us');
    expect(store.countDone(ContentMode.manga), 2000);
    expect(count.elapsedMicroseconds, lessThan(parse.elapsedMicroseconds));
  });

  test('a write drops the cache', () async {
    final before = store.all().length;
    await store.put(
      ChapterDownload(
        id: 'src|https://x/new',
        sourceId: 'src',
        showId: 'show',
        showTitle: 'Show',
        chapterId: 'new',
        chapterUrl: 'https://x/new',
        chapterTitle: 'New',
        mode: ContentMode.manga,
        status: ChapterDownloadStatus.done,
      ),
    );
    expect(store.all().length, before + 1);
  });
}
