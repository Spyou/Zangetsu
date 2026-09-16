import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/mode/content_mode.dart';

void main() {
  late Directory dir;
  late ChapterDownloadStore store;

  ChapterDownload novelRec() => ChapterDownload(
    id: ChapterDownload.idFor('src', 'https://x/c1'),
    sourceId: 'src',
    showId: 'show',
    showTitle: 'Show',
    chapterId: 'c1',
    chapterUrl: 'https://x/c1',
    chapterTitle: 'Chapter 1',
    mode: ContentMode.novel,
    status: ChapterDownloadStatus.downloading,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chapter_store_publish');
    Hive.init(dir.path);
    await ChapterDownloadStore.init();
    await DownloadPrefs.init();
    // A plain path (not content://) routes publish() through a bare
    // File.copy instead of the shared-storage platform channel, which has no
    // implementation in a unit test.
    await DownloadPrefs().setLocation('${dir.path}/drive', 'Test drive');
    sl.registerSingleton<DownloadPrefs>(DownloadPrefs());
    store = ChapterDownloadStore();
  });

  tearDown(() async {
    sl.unregister<DownloadPrefs>();
    await Hive.deleteBoxFromDisk(ChapterDownloadStore.boxName);
    await Hive.deleteBoxFromDisk(DownloadPrefs.boxName);
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'publish keeps textPath on the chapter html, even with an image staged '
    'alongside it',
    () async {
      // img_0.jpg sorts before text.html alphabetically — this is the bug
      // the brief pins: publish() picking the first MOVED file (by sorted
      // path) as the chapter text. Miss it and every downloaded novel with a
      // picture in it reads as empty.
      final staged = await Directory(
        '${dir.path}/staged',
      ).create(recursive: true);
      File('${staged.path}/img_0.jpg').writeAsBytesSync([1, 2, 3]);
      File(
        '${staged.path}/${ChapterDownloadStore.textFile}',
      ).writeAsStringSync('<p>hello</p>');

      final result = await store.publish(novelRec(), staged);

      expect(result.textPath, isNotNull);
      expect(result.textPath, endsWith('/${ChapterDownloadStore.textFile}'));
      expect(await File(result.textPath!).readAsString(), '<p>hello</p>');
    },
  );

  // Deleting a downloaded chapter has to take a novel's whole folder (html +
  // the images saved beside it) but must NEVER take a manga's, whose parent is
  // the show folder shared with every other chapter of that series.
  test('ownedFolder claims a novel chapter folder but never a manga one', () {
    final novel = ChapterDownload(
      id: 'n',
      sourceId: 's',
      showId: 'sh',
      showTitle: 'Show',
      chapterId: 'c1',
      chapterTitle: 'Chapter 1',
      chapterUrl: 'u',
      mode: ContentMode.novel,
      status: ChapterDownloadStatus.done,
      textPath: '/dl/Zangetsu/Show/Chapter 1/text.html',
    );
    expect(
      ChapterDownloadStore.ownedFolder(novel)?.path,
      '/dl/Zangetsu/Show/Chapter 1',
    );

    final manga = ChapterDownload(
      id: 'm',
      sourceId: 's',
      showId: 'sh',
      showTitle: 'Show',
      chapterId: 'c1',
      chapterTitle: 'Chapter 1',
      chapterUrl: 'u',
      mode: ContentMode.manga,
      status: ChapterDownloadStatus.done,
      archivePath: '/dl/Zangetsu/Show/Chapter 1.cbz',
    );
    expect(
      ChapterDownloadStore.ownedFolder(manga),
      isNull,
      reason: "a manga's parent is the SHOW folder — claiming it would delete "
          'every other downloaded chapter of that series',
    );

    // A novel with no html recorded owns nothing to delete.
    expect(
      ChapterDownloadStore.ownedFolder(
        ChapterDownload(
          id: 'x',
          sourceId: 's',
          showId: 'sh',
          showTitle: 'Show',
          chapterId: 'c1',
          chapterTitle: 'C',
          chapterUrl: 'u',
          mode: ContentMode.novel,
          status: ChapterDownloadStatus.done,
        ),
      ),
      isNull,
    );
  });
}
