import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/repository/source_repository.dart';

/// Fetching hangs forever, on purpose. These tests are about the queue, and a
/// fetch that never resolves keeps the first chapter parked in the downloader
/// so the queue can be inspected mid-flight. The downloader runs chapters one
/// at a time, so exactly one is ever in there.
class _FakeSourceRepository implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<PageImage>> pages(String chapterUrl, {String? sourceId}) =>
      Completer<List<PageImage>>().future;

  @override
  Future<ChapterText> chapterText(String chapterUrl, {String? sourceId}) =>
      Completer<ChapterText>().future;
}

/// Counts writes so a regression back to one-write-per-chapter is caught.
class _CountingStore extends ChapterDownloadStore {
  int putCalls = 0;
  int putAllCalls = 0;
  int rowsWritten = 0;

  @override
  Future<void> put(ChapterDownload d) {
    putCalls++;
    rowsWritten++;
    return super.put(d);
  }

  @override
  Future<void> putAll(List<ChapterDownload> ds) {
    putAllCalls++;
    rowsWritten += ds.length;
    return super.putAll(ds);
  }
}

List<Episode> chapters(int n) => [
  for (var i = 0; i < n; i++)
    Episode(
      id: 'c$i',
      title: 'Chapter ${i + 1}',
      url: 'https://x/c$i',
      number: (i + 1).toDouble(),
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _CountingStore store;
  late ChapterDownloader downloader;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chapter_enqueue');
    // The downloader resolves its staging folder through path_provider, which
    // has no implementation in a unit test.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
    Hive.init(dir.path);
    await ChapterDownloadStore.init();
    store = _CountingStore();
    downloader = ChapterDownloader(_FakeSourceRepository(), store);
  });

  tearDown(() async {
    // The parked chapter is mid-`_download` with its first box write still
    // ahead of it. Cancelling trips the guard in front of that write, and the
    // empty-delay lets it unwind before the box goes away underneath it.
    await downloader.cancelAll();
    await Future<void>.delayed(Duration.zero);
    await Hive.deleteBoxFromDisk(ChapterDownloadStore.boxName);
    await Hive.close();
    // The parked chapter may still be creating its staging folder as this
    // runs, which makes a single delete fail with "directory not empty". It's
    // scratch space either way, so retry briefly and let the OS have the rest.
    for (var i = 0; i < 5; i++) {
      try {
        await dir.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test('a batch is one write, not one per chapter', () async {
    // The bug this pins: queueing a long series wrote a Hive row and notified
    // listeners per chapter, so "download all" on a few thousand locked the UI
    // before a single page had been fetched.
    var notifies = 0;
    downloader.addListener(() => notifies++);

    await downloader.enqueueMany(
      chapters: chapters(500),
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      mode: ContentMode.manga,
    );

    expect(store.putAllCalls, 1);
    expect(store.rowsWritten, greaterThanOrEqualTo(500));
    expect(downloader.inFlight.length, 500);
    // The batch itself is one write and one notify. The running chapter adds
    // at most one more of each as it starts — the bug was 500 of them.
    expect(store.putCalls, lessThanOrEqualTo(1));
    expect(notifies, lessThanOrEqualTo(2));
  });

  test('a batch keeps its order so it downloads front to back', () async {
    await downloader.enqueueMany(
      chapters: chapters(3),
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      mode: ContentMode.manga,
    );
    // Stamps have to differ, or the downloads screen has nothing to sort a
    // batch by and shows it in arbitrary order.
    final stamps = store.all().map((c) => c.createdAt).toSet();
    expect(stamps.length, 3);

    final ordered = store.all().toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    expect(
      ordered.map((c) => c.chapterTitle),
      ['Chapter 1', 'Chapter 2', 'Chapter 3'],
    );
  });

  test('already-queued and already-saved chapters are skipped', () async {
    final eps = chapters(3);
    await downloader.enqueueMany(
      chapters: eps,
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      mode: ContentMode.manga,
    );
    // Re-queueing the same run must not double up the queue.
    await downloader.enqueueMany(
      chapters: eps,
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      mode: ContentMode.manga,
    );
    expect(downloader.inFlight.length, 3);
    expect(store.putAllCalls, 1); // second call had nothing fresh to write
  });

  test('stopping everything clears the queue and its records', () async {
    await downloader.enqueueMany(
      chapters: chapters(200),
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      mode: ContentMode.manga,
    );
    await downloader.cancelAll();
    expect(downloader.inFlight, isEmpty);
    // Queued chapters had nothing on disk, so they go entirely — otherwise a
    // stopped batch leaves thousands of dead rows behind.
    expect(store.all().where((c) => c.status != ChapterDownloadStatus.done),
        isEmpty);
  });

  test('a swiped-away queue comes back whole, not as dead rows', () async {
    // Queue a batch, then simulate the app being killed: the records persist
    // as `queued`, which reloads as failed-with-no-error. Only one of them ever
    // had a staging folder, and the rest used to be skipped and left as
    // garbage the user had to clear by hand.
    await downloader.enqueueMany(
      chapters: chapters(200),
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      mode: ContentMode.manga,
    );
    final reloaded = ChapterDownloader(_FakeSourceRepository(), store);
    await reloaded.resumeInterrupted();
    expect(reloaded.inFlight.length, 200);
    await reloaded.cancelAll();
  });

  test('a chapter that failed for a real reason is not retried', () async {
    // A dead source must not re-queue itself on every launch.
    await store.put(
      ChapterDownload(
        id: 'src|https://x/dead',
        sourceId: 'src',
        showId: 'show',
        showTitle: 'Show',
        chapterId: 'dead',
        chapterUrl: 'https://x/dead',
        chapterTitle: 'Dead',
        mode: ContentMode.manga,
        status: ChapterDownloadStatus.failed,
        error: 'HTTP 404',
      ),
    );
    final reloaded = ChapterDownloader(_FakeSourceRepository(), store);
    await reloaded.resumeInterrupted();
    expect(reloaded.inFlight, isEmpty);
  });

  test('a single enqueue still works through the batch path', () async {
    await downloader.enqueue(
      chapter: chapters(1).first,
      sourceId: 'src',
      showId: 'show',
      showTitle: 'Show',
      mode: ContentMode.novel,
    );
    expect(downloader.inFlight.length, 1);
    expect(store.all().single.mode, ContentMode.novel);
  });
}
