import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../di/injector.dart';
import '../logging/app_logger.dart';
import '../mode/content_mode.dart';
import '../models/episode.dart';
import '../models/page_content.dart';
import '../repository/source_repository.dart';
import 'chapter_download.dart';
import 'chapter_download_store.dart';
import 'download_prefs.dart';

/// Fetches manga pages / novel text for offline reading.
///
/// Foreground only — this runs while the app is open and dies with it. A
/// chapter is small enough (seconds, not the tens of minutes a video takes)
/// that the foreground service the video downloader needs would be pure
/// overhead here.
///
/// A chapter caught mid-flight by a kill comes back as `failed` (see
/// [ChapterDownload.fromJson]) with its partial pages intact. [resumeInterrupted]
/// re-queues those on the next launch, and the fetch skips whatever's already
/// in the staging folder, so it picks up where it stopped rather than starting
/// over.
class ChapterDownloader extends ChangeNotifier {
  ChapterDownloader(this._repo, this._store, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  final SourceRepository _repo;
  final ChapterDownloadStore _store;
  final Dio _dio;

  /// How many page images of ONE chapter are fetched at a time — the
  /// "Connections per download" setting, which is the same idea as the segment
  /// connections a video download uses.
  ///
  /// Read through the locator rather than the constructor so tests that don't
  /// register prefs still get the default. Chapters stay strictly one at a
  /// time whatever "Parallel downloads" says: several chapters at once
  /// multiplies the per-host request rate and is what gets a source to start
  /// answering 403.
  int get _pageConcurrency => sl.isRegistered<DownloadPrefs>()
      ? sl<DownloadPrefs>().connectionsPerDownload
      : 4;

  /// Chapters download one after another. Racing several would multiply the
  /// per-host request rate by the queue length and get us 429'd.
  final List<String> _queue = [];
  final Map<String, ChapterDownload> _live = {};
  final Set<String> _cancelled = {};
  bool _running = false;

  int _lastWriteMs = 0;

  /// Queued + downloading chapters with live progress, keyed by id. Records
  /// that have finished (or failed) leave here and live in the store.
  Map<String, ChapterDownload> get inFlight => Map.unmodifiable(_live);

  ChapterDownload? progressOf(String id) => _live[id];

  bool isBusy(String id) => _live.containsKey(id);

  /// Re-queue everything a kill interrupted. Called once at startup.
  ///
  /// `error == null` is what separates the two kinds of failure: a chapter that
  /// failed for a real reason (dead source, 404) always carries a message, and
  /// retrying those on every launch would be a loop the user can't get out of.
  /// A killed one never got to write an error.
  ///
  /// Deliberately not restricted to chapters with pages already on disk. Most
  /// of an interrupted batch never started — queue a few hundred, swipe the app
  /// away, and only the one that was running would have a staging folder. The
  /// rest would sit as dead rows the user has to clear by hand.
  Future<void> resumeInterrupted() async {
    var pages = 0;
    for (final rec in _store.all()) {
      if (rec.status != ChapterDownloadStatus.failed) continue;
      if (rec.error != null) continue; // failed loudly, not killed
      if (_live.containsKey(rec.id)) continue;
      _cancelled.remove(rec.id);
      _live[rec.id] = rec.copyWith(status: ChapterDownloadStatus.queued);
      _queue.add(rec.id);
      if (rec.pagesDone > 0) pages++;
    }
    if (_queue.isEmpty) return;
    AppLogger.instance.log(
      '[chapters] resuming ${_queue.length} interrupted '
      '($pages part-downloaded)',
    );
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> enqueue({
    required Episode chapter,
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    required ContentMode mode,
  }) => enqueueMany(
    chapters: [chapter],
    sourceId: sourceId,
    showId: showId,
    showTitle: showTitle,
    cover: cover,
    mode: mode,
  );

  /// Queue a run of chapters as one unit.
  ///
  /// The whole batch is one box write and one notify. Looping [enqueue] over a
  /// long series did both per chapter, so queueing a few thousand froze the UI
  /// before a single page had been fetched.
  Future<void> enqueueMany({
    required List<Episode> chapters,
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    required ContentMode mode,
  }) async {
    // Timestamps step by one so a batch keeps its list order. Stamping them
    // all `now` would leave the sort with nothing to separate them, and the
    // downloads screen reads this back as reading order.
    final base = DateTime.now().millisecondsSinceEpoch;
    final fresh = <ChapterDownload>[];

    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final id = ChapterDownload.idFor(sourceId, chapter.url);
      if (_live.containsKey(id)) continue;
      if (_store.isDownloaded(sourceId, chapter.url)) continue;
      _cancelled.remove(id);

      final rec = ChapterDownload(
        id: id,
        sourceId: sourceId,
        showId: showId,
        showTitle: showTitle,
        cover: cover,
        chapterId: chapter.id,
        chapterUrl: chapter.url,
        chapterTitle: chapter.title,
        mode: mode,
        number: chapter.number,
        status: ChapterDownloadStatus.queued,
        createdAt: base + i,
      );
      _live[id] = rec;
      _queue.add(id);
      fresh.add(rec);
    }

    if (fresh.isEmpty) return;
    await _store.putAll(fresh);
    notifyListeners();
    unawaited(_pump());
  }

  /// Stops a download and throws away whatever it had — both the record and
  /// the files. A running chapter notices between pages; the mop-up happens
  /// when its loop unwinds.
  Future<void> cancel(String id) async {
    _cancelled.add(id);
    _queue.remove(id);
    final wasQueued = _live.remove(id)?.status == ChapterDownloadStatus.queued;
    notifyListeners();
    // A downloading chapter cleans up its own part folder on the way out —
    // doing it here would race the workers still writing into it.
    if (wasQueued) await _store.remove(id);
  }

  /// Stop everything: the running chapter and the whole queue behind it.
  ///
  /// Queueing hundreds of chapters is one tap, so unqueueing them has to be
  /// one tap too — cancelling them one at a time isn't a real option at that
  /// size.
  Future<void> cancelAll() async {
    final queued = _live.values
        .where((c) => c.status == ChapterDownloadStatus.queued)
        .map((c) => c.id)
        .toList();
    _cancelled.addAll(_live.keys);
    _queue.clear();
    _live.clear();
    notifyListeners();
    // The running chapter clears its own part folder as its loop unwinds;
    // doing it here would race the workers still writing into it.
    for (final id in queued) {
      await _store.remove(id);
    }
  }

  /// Drop every record that failed, and the part files behind them. The
  /// leftovers after a big queue is stopped are noise, not something to page
  /// through with an X per row.
  Future<int> clearFailed() async {
    final dead = _store
        .all()
        .where(
          (c) =>
              c.status == ChapterDownloadStatus.failed &&
              !_live.containsKey(c.id),
        )
        .toList();
    for (final c in dead) {
      await _store.remove(c.id);
    }
    if (dead.isNotEmpty) notifyListeners();
    return dead.length;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        await _download(_queue.removeAt(0));
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _download(String id) async {
    final start = _live[id];
    if (start == null) return;
    var rec = start;

    final dir = await _store.dirFor(rec);
    final part = Directory('${dir.path}${ChapterDownloadStore.partSuffix}');

    try {
      if (_cancelled.contains(id)) return;
      rec = rec.copyWith(
        status: ChapterDownloadStatus.downloading,
        error: () => null,
      );
      await _emit(rec, force: true);
      await part.create(recursive: true);

      if (rec.mode == ContentMode.novel) {
        rec = await _downloadText(rec, part);
      } else {
        rec = await _downloadPages(rec, part);
      }
      if (_cancelled.contains(id)) return;

      // Rename last: until this moment nothing reads as downloaded.
      await ChapterDownloadStore.deleteDir(dir);
      await part.rename(dir.path);
      // Then out of app storage and into the user's download folder. Falls
      // back to leaving it here if that move fails, so the chapter is readable
      // either way.
      rec = await _store.publish(rec, dir);

      rec = rec.copyWith(status: ChapterDownloadStatus.done);
      _live.remove(id);
      await _store.put(rec);
      notifyListeners();
    } catch (e) {
      if (_cancelled.contains(id)) return;
      AppLogger.instance.log(
        '[chapters] ${rec.showTitle} · ${rec.chapterTitle} failed — $e',
        level: 'E',
      );
      // Partial pages stay in the .part folder so a retry skips them.
      _live.remove(id);
      await _store.put(
        rec.copyWith(
          status: ChapterDownloadStatus.failed,
          error: () => _humanError(e),
        ),
      );
      notifyListeners();
    } finally {
      if (_cancelled.remove(id)) {
        await ChapterDownloadStore.deleteDir(part);
        await _store.remove(id);
        _live.remove(id);
        notifyListeners();
      }
    }
  }

  Future<ChapterDownload> _downloadText(
    ChapterDownload rec,
    Directory part,
  ) async {
    final text = await _repo.chapterText(rec.chapterUrl, sourceId: rec.sourceId);
    if (text.html.trim().isEmpty) throw Exception('Chapter has no text');
    final (html, imageBytes) = await _downloadImages(
      text.html,
      rec.chapterUrl,
      part,
    );
    final file = File('${part.path}/${ChapterDownloadStore.textFile}');
    await file.writeAsString(html, flush: true);
    return rec.copyWith(bytes: await file.length() + imageBytes);
  }

  /// Matches an `<img … src="…">` tag's `src` attribute — group 1 is
  /// everything up to and including `src=`, group 2 the quote character used,
  /// group 3 the URL between the quotes. Requires whitespace right before
  /// `src` so a lazy-load `data-src` attribute is never mistaken for it.
  static final RegExp _imgTagSrc = RegExp(
    r'''(<img\b[^>]*\ssrc\s*=\s*)(["'])(.*?)\2''',
    caseSensitive: false,
    dotAll: true,
  );

  /// Downloads every image an `<img>` tag in [html] points at into [part] as
  /// `img_0.<ext>`, `img_1.<ext>` … and rewrites that tag's `src` to the bare
  /// filename, so the folder reads offline wherever it ends up moved to.
  ///
  /// A relative `src` is resolved against [chapterUrl] first. `data:` URIs
  /// are left alone — already inline, nothing to fetch. One image failing to
  /// download leaves its tag untouched rather than failing the whole
  /// chapter: a chapter with one broken picture beats no chapter.
  ///
  /// Returns the rewritten html and the total bytes written to disk.
  Future<(String, int)> _downloadImages(
    String html,
    String chapterUrl,
    Directory part,
  ) async {
    final matches = _imgTagSrc.allMatches(html).toList();
    if (matches.isEmpty) return (html, 0);

    final base = Uri.tryParse(chapterUrl);
    final out = StringBuffer();
    var cursor = 0;
    var bytes = 0;
    var index = 0;

    for (final m in matches) {
      out.write(html.substring(cursor, m.start));
      cursor = m.end;
      final src = m.group(3)!;

      if (src.startsWith('data:')) {
        out.write(m.group(0));
        continue;
      }

      final resolved = base?.resolve(src) ?? Uri.tryParse(src);
      if (resolved == null) {
        out.write(m.group(0));
        continue;
      }

      try {
        final res = await _dio.get<List<int>>(
          resolved.toString(),
          options: Options(responseType: ResponseType.bytes),
        );
        final data = res.data;
        if (data == null || data.isEmpty) throw Exception('Empty image');
        final name = 'img_$index${_imgExt(resolved.path)}';
        await File(
          '${part.path}/$name',
        ).writeAsBytes(data, flush: true);
        bytes += data.length;
        out
          ..write(m.group(1))
          ..write(m.group(2))
          ..write(name)
          ..write(m.group(2));
        index++;
      } catch (e) {
        AppLogger.instance.log(
          '[chapters] image skipped — $e',
          level: 'W',
        );
        out.write(m.group(0));
      }
    }
    out.write(html.substring(cursor));
    return (out.toString(), bytes);
  }

  static String _imgExt(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '.img' : path.substring(dot);
  }

  Future<ChapterDownload> _downloadPages(
    ChapterDownload rec,
    Directory part,
  ) async {
    final pages = await _repo.pages(rec.chapterUrl, sourceId: rec.sourceId);
    if (pages.isEmpty) throw Exception('Chapter has no pages');

    var current = rec.copyWith(pageCount: pages.length, pagesDone: 0, bytes: 0);
    await _emit(current, force: true);

    var next = 0;
    var done = 0;
    var bytes = 0;
    Object? firstError;

    Future<void> worker() async {
      while (firstError == null && !_cancelled.contains(rec.id)) {
        final i = next++;
        if (i >= pages.length) return;
        final file = File('${part.path}/${_pageName(i, pages[i].url)}');
        try {
          // Read-modify-write in one go — `bytes += await …` would read the
          // old value before the await and lose the other workers' updates.
          final size = await _fetchPage(pages[i], file);
          bytes += size;
        } catch (e) {
          firstError ??= e;
          return;
        }
        done++;
        current = current.copyWith(pagesDone: done, bytes: bytes);
        await _emit(current);
      }
    }

    await Future.wait([
      for (var i = 0; i < _pageConcurrency; i++) worker(),
    ]);
    if (firstError != null) throw firstError!;
    return current;
  }

  /// Tries per page. Three, matching the HLS segment budget — the failure and
  /// the fix are the same shape on both paths.
  static const int _pageAttempts = 3;

  /// Multiplied by the attempt number: 400ms, then 800ms.
  static const Duration _pageRetryDelay = Duration(milliseconds: 400);

  /// A 4xx means the CDN has answered and the answer is no — usually a dead
  /// link or a missing Referer. Retrying only makes the failure slower.
  static bool _isPermanent(DioException e) {
    final code = e.response?.statusCode;
    return code != null && code >= 400 && code < 500;
  }

  /// Returns the page's size on disk. A file already there from an earlier
  /// attempt is reused rather than re-fetched.
  Future<int> _fetchPage(PageImage page, File file) async {
    if (await file.exists()) {
      final size = await file.length();
      if (size > 0) return size;
    }
    // The headers matter more here than anywhere else in the app: most manga
    // CDNs are Referer-locked or behind Cloudflare and answer a bare GET with
    // 403. They come from the source alongside the URL — always send them.
    //
    // Tried [_pageAttempts] times: one page failing used to fail the whole
    // chapter, and a sixty-page chapter over a patchy connection gives that
    // plenty of chances. Pages already on disk are skipped above, so a retry
    // only re-fetches what is actually missing.
    List<int>? data;
    for (var attempt = 1; attempt <= _pageAttempts; attempt++) {
      try {
        final res = await _dio.get<List<int>>(
          page.url,
          options: Options(
            headers: page.headers,
            responseType: ResponseType.bytes,
          ),
        );
        data = res.data;
        if (data != null && data.isNotEmpty) break;
      } catch (e) {
        // A CDN that says no is not going to say yes on the third ask.
        if (e is DioException && _isPermanent(e)) rethrow;
        if (attempt == _pageAttempts) rethrow;
      }
      if (attempt < _pageAttempts) {
        await Future<void>.delayed(_pageRetryDelay * attempt);
      }
    }
    if (data == null || data.isEmpty) throw Exception('Empty image');
    // Write under a temp name so a kill mid-write can't leave a truncated file
    // that the retry then counts as already done.
    final tmp = File('${file.path}${ChapterDownloadStore.partSuffix}');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(file.path);
    return data.length;
  }

  /// Hive write throttled to ~2/s. The in-memory notify is unthrottled — a
  /// progress bar should move on every page, but a 60-page chapter shouldn't
  /// cost 60 box writes.
  Future<void> _emit(ChapterDownload rec, {bool force = false}) async {
    if (_cancelled.contains(rec.id)) return;
    _live[rec.id] = rec;
    notifyListeners();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastWriteMs < 500) return;
    _lastWriteMs = now;
    await _store.put(rec);
  }

  static String _pageName(int index, String url) =>
      '${(index + 1).toString().padLeft(3, '0')}${_ext(url)}';

  static const Set<String> _imageExts = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.avif',
    '.bmp',
  };

  static String _ext(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '.jpg';
    final ext = path.substring(dot).toLowerCase();
    return _imageExts.contains(ext) ? ext : '.jpg';
  }

  static String _humanError(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 403 || code == 401) return 'Source blocked the download';
      if (code == 429) return 'Source is rate limiting — try again later';
      if (code != null) return 'Source returned $code';
      return 'Network error';
    }
    if (e is UnsupportedError) return "This source can't be downloaded";
    final msg = e.toString().replaceFirst('Exception: ', '').split('\n').first;
    return msg.length > 120 ? '${msg.substring(0, 117)}…' : msg;
  }
}
