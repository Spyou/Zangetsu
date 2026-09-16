import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/repository/source_repository.dart';

/// Hands back fixed HTML for every chapter — the download side only asks
/// for one chapter, so nothing here needs to key off the URL.
class _FakeTextRepo implements SourceRepository {
  _FakeTextRepo(this.html);
  final String html;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  Future<ChapterText> chapterText(String chapterUrl, {String? sourceId}) async =>
      ChapterText(html: html);
}

/// A GET to any URL containing "fail" 404s; everything else answers with a
/// fixed 4-byte body, so a test can prove exactly which images went through.
class _ImgAdapter implements HttpClientAdapter {
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, _) async {
    requested.add(o.uri.toString());
    if (o.uri.toString().contains('fail')) {
      return ResponseBody.fromString('nope', 404);
    }
    return ResponseBody.fromBytes(Uint8List.fromList([1, 2, 3, 4]), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ChapterDownloadStore store;
  late _ImgAdapter adapter;
  late ChapterDownloader downloader;

  // One absolute image (fetched as-is), one relative image (resolved
  // against the chapter url), one that 404s, and one already-inline data
  // URI — covers every branch _downloadImages has to make a call on.
  const html =
      '<p>intro</p>'
      '<img src="https://x/ok.jpg">'
      '<img src="rel.png">'
      '<img src="https://x/fail.jpg">'
      '<img src="data:image/gif;base64,AAAA">'
      '<p>outro</p>';
  const chapterUrl = 'https://x/c1';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chapter_img_dl');
    // The downloader resolves its staging folder through path_provider,
    // which has no implementation in a unit test.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    Hive.init(dir.path);
    await ChapterDownloadStore.init();
    await DownloadPrefs.init();
    // A plain path (not content://) routes publish() through a bare
    // File.copy instead of the shared-storage platform channel, which isn't
    // mocked here — so the record's textPath actually gets set and the
    // published folder is easy to find.
    await DownloadPrefs().setLocation('${dir.path}/drive', 'Test drive');
    sl.registerSingleton<DownloadPrefs>(DownloadPrefs());
    store = ChapterDownloadStore();

    adapter = _ImgAdapter();
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 2)));
    dio.httpClientAdapter = adapter;
    downloader = ChapterDownloader(_FakeTextRepo(html), store, dio: dio);
  });

  tearDown(() async {
    sl.unregister<DownloadPrefs>();
    await Hive.deleteBoxFromDisk(ChapterDownloadStore.boxName);
    await Hive.deleteBoxFromDisk(DownloadPrefs.boxName);
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> waitUntilDone(String id) async {
    for (var i = 0; i < 400; i++) {
      if (!downloader.isBusy(id)) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('chapter never finished downloading');
  }

  test(
    'downloads the images an offline chapter references and rewrites their '
    'src to bare filenames, without failing on the one that 404s',
    () async {
      final id = ChapterDownload.idFor('src', chapterUrl);

      await downloader.enqueue(
        chapter: Episode(
          id: 'c1',
          title: 'Chapter 1',
          url: chapterUrl,
          number: 1,
        ),
        sourceId: 'src',
        showId: 'show',
        showTitle: 'Show',
        mode: ContentMode.novel,
      );
      await waitUntilDone(id);

      final rec = store.get(id)!;
      expect(rec.status, ChapterDownloadStatus.done);
      expect(rec.textPath, isNotNull);

      final savedHtml = await File(rec.textPath!).readAsString();
      final folder = File(rec.textPath!).parent.path;

      // The two fetchable images were saved and renamed in encounter order —
      // the relative one resolved against the chapter url.
      expect(savedHtml, contains('src="img_0.jpg"'));
      expect(savedHtml, contains('src="img_1.png"'));
      expect(await File('$folder/img_0.jpg').exists(), isTrue);
      expect(await File('$folder/img_1.png').exists(), isTrue);
      expect(adapter.requested, contains('https://x/ok.jpg'));
      expect(adapter.requested, contains('https://x/rel.png'));

      // The 404 and the data: URI are left exactly as they were — one
      // broken picture must not fail the chapter, and an inline image has
      // nothing to fetch.
      expect(savedHtml, contains('src="https://x/fail.jpg"'));
      expect(savedHtml, contains('src="data:image/gif;base64,AAAA"'));
      expect(await File('$folder/img_2.jpg').exists(), isFalse);

      // bytes on the record covers the images too, not just the html.
      final htmlBytes = await File(rec.textPath!).length();
      expect(rec.bytes, htmlBytes + 8); // two 4-byte fakes
    },
  );
}
