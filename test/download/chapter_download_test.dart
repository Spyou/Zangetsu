import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/mode/content_mode.dart';

ChapterDownload rec({
  ChapterDownloadStatus status = ChapterDownloadStatus.done,
  int pageCount = 0,
  int pagesDone = 0,
}) => ChapterDownload(
  id: ChapterDownload.idFor('src', 'https://x/c1'),
  sourceId: 'src',
  showId: 'show',
  showTitle: 'Show',
  chapterId: 'c1',
  chapterUrl: 'https://x/c1',
  chapterTitle: 'Chapter 1',
  mode: ContentMode.manga,
  status: status,
  pageCount: pageCount,
  pagesDone: pagesDone,
);

void main() {
  group('ChapterDownload', () {
    test('id is keyed on the chapter URL, not the chapter id', () {
      // Some sources hand back fresh chapter ids on a refetch. Keying on those
      // would orphan every download the next time the list reloads.
      expect(
        ChapterDownload.idFor('src', 'https://x/c1'),
        ChapterDownload.idFor('src', 'https://x/c1'),
      );
      expect(
        ChapterDownload.idFor('src', 'https://x/c1'),
        isNot(ChapterDownload.idFor('other', 'https://x/c1')),
      );
    });

    test('progress reports the fraction of pages fetched', () {
      expect(
        rec(
          status: ChapterDownloadStatus.downloading,
          pageCount: 40,
          pagesDone: 10,
        ).progress,
        0.25,
      );
      // A novel is one blob with no page count — it must not divide by zero.
      expect(
        rec(status: ChapterDownloadStatus.downloading).progress,
        0,
      );
      expect(rec().progress, 1); // done is done whatever the counts say
    });

    test('a download caught mid-flight by a kill comes back failed', () {
      // The app has no resume, so a record that was `downloading` when the
      // process died would otherwise reload as a progress bar that never moves.
      final live = rec(status: ChapterDownloadStatus.downloading).toJson();
      expect(live['status'], 'downloading');
      final back = ChapterDownload.fromJson(live)!;
      expect(back.status, ChapterDownloadStatus.failed);
      expect(back.isActive, isFalse);
    });

    test('done and failed survive a round trip', () {
      for (final s in [
        ChapterDownloadStatus.done,
        ChapterDownloadStatus.failed,
      ]) {
        expect(ChapterDownload.fromJson(rec(status: s).toJson())!.status, s);
      }
    });

    test('a junk record is dropped rather than throwing', () {
      expect(ChapterDownload.fromJson(null), isNull);
      expect(ChapterDownload.fromJson({'id': ''}), isNull);
      expect(ChapterDownload.fromJson({'nope': 1}), isNull);
    });

    test('an unknown mode falls back to manga instead of throwing', () {
      final j = rec().toJson()..['mode'] = 'audiobook';
      expect(ChapterDownload.fromJson(j)!.mode, ContentMode.manga);
    });

    test('published page paths survive a round trip', () {
      // These are the only record of where a chapter went once it's in the
      // shared Downloads folder — losing them orphans the files.
      final r = rec().copyWith(pagePaths: ['/a/001.jpg', '/a/002.jpg']);
      final back = ChapterDownload.fromJson(r.toJson())!;
      expect(back.pagePaths, ['/a/001.jpg', '/a/002.jpg']);
    });

    test('a record from before publishing existed still loads', () {
      // Chapters saved by the previous build have no pagePaths/textPath/number
      // key at all. They must keep working off their app-private folder.
      final old = rec().toJson()
        ..remove('pagePaths')
        ..remove('textPath')
        ..remove('number');
      final back = ChapterDownload.fromJson(old)!;
      expect(back.pagePaths, isEmpty);
      expect(back.textPath, isNull);
      expect(back.number, isNull);
    });

    test('copyWith keeps the fields it was not asked to change', () {
      // copyWith is how the downloader threads a record through the whole run,
      // so anything it silently drops is lost by the time the chapter is done.
      final r = rec().copyWith(pagePaths: ['/a/001.jpg']);
      final done = r.copyWith(status: ChapterDownloadStatus.done);
      expect(done.pagePaths, ['/a/001.jpg']);
      expect(done.number, r.number);
      expect(done.chapterUrl, r.chapterUrl);
    });

    test('a killed download is told apart from one that really failed', () {
      // resumeInterrupted retries only the killed ones — a source that 404s
      // would otherwise retry itself on every launch forever.
      final killed = ChapterDownload.fromJson(
        rec(status: ChapterDownloadStatus.downloading).toJson(),
      )!;
      expect(killed.status, ChapterDownloadStatus.failed);
      expect(killed.error, isNull);

      final broke = ChapterDownload.fromJson(
        rec(status: ChapterDownloadStatus.failed)
            .copyWith(error: () => 'HTTP 404')
            .toJson(),
      )!;
      expect(broke.error, 'HTTP 404');
    });
  });
}
