import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/episode.dart';
import '../models/video_source.dart';
import '../repository/source_repository.dart';
import 'download_prefs.dart';
import 'download_record.dart';
import 'download_service.dart';

/// Owns offline downloads. Direct-file (MP4/MKV) sources go through
/// background_downloader (true background); HLS (m3u8) sources go through the
/// in-app [HlsDownloader] (segment fetch + decrypt + concat, foreground). Both
/// finish in the public Downloads folder. Records persist in the Hive
/// `downloads` box so the library survives restarts. A [ChangeNotifier] so the
/// UI can rebuild live. See docs/downloads-feature.md.
class DownloadManager extends ChangeNotifier {
  DownloadManager(this._repo, [DownloadPrefs? downloadPrefs])
      : _downloadPrefs = downloadPrefs ?? DownloadPrefs();

  final SourceRepository _repo;
  // ignore: unused_field — consumed in Task 3 (MP4 publish branch)
  final DownloadPrefs _downloadPrefs;

  static const String boxName = 'downloads';
  static const String _sharedDir = 'Zangetsu';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  final FileDownloader _dl = FileDownloader();
  // Small HTTP client for fetching subtitle sidecar files (they're tiny, so a
  // direct GET in the UI isolate beats threading them through the downloaders).
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  /// In-memory cache of records, keyed by id (mirrors the Hive box).
  final Map<String, DownloadRecord> _records = {};
  // Live DownloadTask objects for in-session control (pause/resume/move).
  final Map<String, DownloadTask> _tasks = {};
  // Remaining fallback mirrors per record (CloudStream-style try-next): when a
  // download fails or saves a web page, we advance to the next candidate.
  final Map<String, List<VideoSource>> _candidates = {};
  StreamSubscription<TaskUpdate>? _sub;

  /// Wire notifications + the update streams. Call once at app start.
  void setup() {
    for (final raw in _box.values) {
      final r = DownloadRecord.fromMap(raw);
      _records[r.id] = r;
    }
    _dl.configureNotification(
      running: const TaskNotification('Downloading', '{filename}'),
      complete: const TaskNotification('Downloaded', '{filename}'),
      error: const TaskNotification('Download failed', '{filename}'),
      progressBar: true,
    );
    _sub = _dl.updates.listen(_onUpdate);
    _listenBackgroundService();
    _reconcileServiceResults(); // apply HLS downloads finished while killed
  }

  /// Apply progress/done/failed events the foreground-service isolate sends for
  /// HLS downloads (live, while the UI is alive).
  void _listenBackgroundService() {
    final svc = DownloadService.instance;
    svc.on('progress').listen((d) {
      final id = d?['id'] as String?;
      if (id == null) return;
      final rec = _records[id];
      if (rec == null || rec.status == DownloadStatus.canceled) return;
      final p = (d?['progress'] as num?)?.toDouble() ?? rec.progress;
      _put(rec.copyWith(status: DownloadStatus.downloading, progress: p));
      notifyListeners();
    });
    svc.on('done').listen((d) {
      final id = d?['id'] as String?;
      if (id == null) return;
      final rec = _records[id];
      if (rec == null) return;
      _candidates.remove(id);
      final path = d?['filePath'] as String?;
      _put(rec.copyWith(
        status: DownloadStatus.done,
        progress: 1,
        filePath: () => path,
      ));
      notifyListeners();
    });
    svc.on('failed').listen((d) async {
      final id = d?['id'] as String?;
      if (id == null) return;
      final rec = _records[id];
      if (rec == null || d?['canceled'] == true) return;
      if (await _tryNext(rec)) return;
      _put(rec.copyWith(
        status: DownloadStatus.failed,
        error: () => d?['error'] as String? ?? 'Download failed',
      ));
      notifyListeners();
    });
  }

  /// Read completion markers written by the service while the app was killed,
  /// apply them to records, then delete them.
  Future<void> _reconcileServiceResults() async {
    try {
      final dir = await DownloadService.resultsDir();
      if (!await dir.exists()) return;
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final m = jsonDecode(await entity.readAsString()) as Map;
          final id = m['id'] as String?;
          final rec = id == null ? null : _records[id];
          if (rec != null && rec.status != DownloadStatus.done) {
            final status = m['status'] as String?;
            if (status == 'done') {
              _candidates.remove(id);
              _put(rec.copyWith(
                status: DownloadStatus.done,
                progress: 1,
                filePath: () => m['filePath'] as String?,
              ));
            } else if (status == 'failed') {
              _put(rec.copyWith(
                status: DownloadStatus.failed,
                error: () => m['error'] as String? ?? 'Download failed',
              ));
            }
          }
        } catch (_) {}
        try {
          await entity.delete();
        } catch (_) {}
      }
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ── Reads ────────────────────────────────────────────────────────────────

  List<DownloadRecord> get all =>
      _records.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Records grouped by show, newest show first.
  Map<String, List<DownloadRecord>> get byShow {
    final out = <String, List<DownloadRecord>>{};
    for (final r in all) {
      (out[r.showId] ??= []).add(r);
    }
    return out;
  }

  DownloadRecord? recordFor(String sourceId, String showId, String episodeId) =>
      _records[_idFor(sourceId, showId, episodeId)];

  // ── Enqueue ───────────────────────────────────────────────────────────────

  /// Persist a [DownloadStatus.queued] record for each episode, then resolve +
  /// enqueue them in the background. Safe to not await.
  Future<void> enqueueEpisodes({
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    required String showUrl,
    required String category,
    required String quality,
    required List<Episode> episodes,
    required int nowMs,
    int? malId,
  }) async {
    // Best-effort notification permission so the progress notification shows.
    try {
      await Permission.notification.request();
    } catch (_) {}

    final pending = <DownloadRecord>[];
    for (final ep in episodes) {
      final id = _idFor(sourceId, showId, ep.id);
      final existing = _records[id];
      // Skip ones already done or in flight.
      if (existing != null &&
          (existing.status == DownloadStatus.done || existing.isActive)) {
        continue;
      }
      final rec = DownloadRecord(
        id: id,
        sourceId: sourceId,
        showId: showId,
        showTitle: showTitle,
        cover: cover,
        coverHeaders: coverHeaders,
        showUrl: showUrl,
        episodeId: ep.id,
        episodeUrl: ep.url,
        episodeNumber: ep.number,
        episodeTitle: ep.title,
        category: category,
        quality: quality,
        malId: malId,
        createdAt: nowMs,
      );
      _put(rec);
      pending.add(rec);
    }
    notifyListeners();

    for (final rec in pending) {
      await _resolveAndEnqueue(rec);
    }
  }

  /// Enqueue a single episode against an ALREADY-CHOSEN source (the CloudStream
  /// "pick a server" flow) — no re-resolution, so the exact url + headers the
  /// player would stream are what we download.
  Future<void> enqueueSource({
    required String sourceId,
    required String showId,
    required String showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    required String showUrl,
    required String category,
    required Episode episode,
    required VideoSource source,
    required String qualityLabel,
    required int nowMs,
    int? malId,
    List<VideoSource> fallbacks = const [],
  }) async {
    try {
      await Permission.notification.request();
    } catch (_) {}
    final rec = DownloadRecord(
      id: _idFor(sourceId, showId, episode.id),
      sourceId: sourceId,
      showId: showId,
      showTitle: showTitle,
      cover: cover,
      coverHeaders: coverHeaders,
      showUrl: showUrl,
      episodeId: episode.id,
      episodeUrl: episode.url,
      episodeNumber: episode.number,
      episodeTitle: episode.title,
      category: category,
      quality: qualityLabel,
      malId: malId,
      createdAt: nowMs,
    );
    _put(rec);
    notifyListeners();
    // The user's chosen source first, then the other mirrors as fallback (so a
    // dead mirror auto-advances instead of just failing).
    _candidates[rec.id] = [
      source,
      ...fallbacks.where((s) => s.url != source.url),
    ];
    await _enqueueTaskFor(rec, source);
  }

  /// Resolve a source for [rec] (batch path) then enqueue it, keeping the rest
  /// as fallback mirrors.
  Future<void> _resolveAndEnqueue(DownloadRecord rec) async {
    _put(rec.copyWith(status: DownloadStatus.resolving));
    notifyListeners();
    try {
      final sources = await _repo.sources(rec.episodeUrl, sourceId: rec.sourceId);
      if (_isCanceled(rec.id)) return; // canceled while resolving
      final ranked = _ranked(sources, rec.quality);
      if (ranked.isEmpty) {
        _put(
          rec.copyWith(
            status: DownloadStatus.unsupported,
            error: () => 'No downloadable (non-HLS) source',
          ),
        );
        notifyListeners();
        return;
      }
      _candidates[rec.id] = ranked;
      await _enqueueTaskFor(rec, ranked.first);
    } catch (e) {
      _put(
        rec.copyWith(status: DownloadStatus.failed, error: () => 'Resolve failed'),
      );
      notifyListeners();
    }
  }

  /// Advance [rec] to its next fallback mirror. Returns true if one was
  /// enqueued, false when mirrors are exhausted.
  Future<bool> _tryNext(DownloadRecord rec) async {
    final cands = _candidates[rec.id];
    if (cands == null || cands.length <= 1) return false;
    cands.removeAt(0); // drop the one that just failed
    if (cands.isEmpty) return false;
    _put(rec.copyWith(status: DownloadStatus.resolving, progress: 0));
    notifyListeners();
    await _enqueueTaskFor(rec, cands.first);
    return true;
  }

  /// Start [rec] from a concrete [source] — HLS via the in-app segment
  /// downloader, everything else via background_downloader.
  Future<void> _enqueueTaskFor(DownloadRecord rec, VideoSource source) async {
    if (_isCanceled(rec.id)) return; // don't (re)start a canceled download
    // Save any soft subtitles this source advertises, in parallel with the
    // video (they're tiny and best-effort — never block or fail the download).
    unawaited(_fetchSubtitles(rec, source));
    if (_isHls(source)) {
      await _startHlsDownload(rec, source);
      return;
    }
    final task = DownloadTask(
      taskId: rec.id,
      url: source.url,
      filename: '${_safe(rec.showTitle)}_E${rec.episodeNumber?.toInt() ?? ''}'
          '_${_safe(rec.quality)}${_ext(source.url)}',
      headers: source.headers ?? const {},
      directory: '$_sharedDir/${_safe(rec.showTitle)}',
      baseDirectory: BaseDirectory.applicationDocuments,
      updates: Updates.statusAndProgress,
      // Flaky file hosts (4khdhub's HubCloud/gamerxyt CDN) drop the connection
      // mid-transfer. The streaming path survives this via mpv's auto-reconnect;
      // the download path had retries:0, so a single drop failed the task and
      // we cycled to the next mirror from 0 (the "restart at 3%" loop). With
      // retries + allowPause, background_downloader RESUMES from the partial
      // (the host supports range — mpv can seek it) on each drop instead of
      // restarting. waitingToRetry / negative retry-progress are already handled
      // in _onUpdate, so this only adds resilience.
      retries: 5,
      allowPause: true,
      displayName: '${rec.showTitle} · E${rec.episodeNumber?.toInt() ?? ''}',
    );
    _tasks[rec.id] = task;
    final ok = await _dl.enqueue(task);
    if (!ok) {
      if (await _tryNext(rec)) return;
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () => "Couldn't start download",
        ),
      );
      notifyListeners();
    }
  }

  /// Hand an HLS source to the foreground-service isolate so it downloads in
  /// true background. We resolve the path here (UI isolate owns path_provider),
  /// start the service, and dispatch the job; progress/done/failed come back via
  /// [_listenBackgroundService].
  Future<void> _startHlsDownload(DownloadRecord rec, VideoSource source) async {
    _put(rec.copyWith(status: DownloadStatus.downloading, progress: 0));
    notifyListeners();
    try {
      final docs = await getApplicationDocumentsDirectory();
      final safeShow = _safe(rec.showTitle);
      final dir = Directory('${docs.path}/$_sharedDir/$safeShow');
      await dir.create(recursive: true);
      final outputPath =
          '${dir.path}/${safeShow}_E${rec.episodeNumber?.toInt() ?? ''}'
          '_${_safe(rec.quality)}.mp4';

      if (!await DownloadService.instance.isRunning()) {
        await DownloadService.instance.startService();
      }
      DownloadService.instance.invoke('download', {
        'id': rec.id,
        'url': source.url,
        'headers': source.headers ?? const <String, String>{},
        'outputPath': outputPath,
        'quality': rec.quality,
        'label': 'E${rec.episodeNumber?.toInt() ?? ''}',
        'showTitle': rec.showTitle,
        'sharedSubDir': '$_sharedDir/$safeShow',
      });
    } catch (_) {
      if (_isCanceled(rec.id)) return;
      if (await _tryNext(rec)) return;
      _put(
        rec.copyWith(
          status: DownloadStatus.failed,
          error: () => "Couldn't start download",
        ),
      );
      notifyListeners();
    }
  }

  /// Download the soft-subtitle sidecar files a [source] advertises and record
  /// their local paths on [rec], so soft-subbed sources keep subtitles offline.
  /// Best-effort: stored in private app storage, idempotent (skips if already
  /// saved), and any failure just leaves the download without sidecar subs.
  Future<void> _fetchSubtitles(DownloadRecord rec, VideoSource source) async {
    if (source.subtitles.isEmpty) return;
    final live = _records[rec.id];
    if (live == null || live.status == DownloadStatus.canceled) return;
    if (live.subtitles.isNotEmpty) return; // already saved (e.g. a retry mirror)
    try {
      final docs = await getApplicationDocumentsDirectory();
      final safeShow = _safe(rec.showTitle);
      final dir = Directory('${docs.path}/$_sharedDir/$safeShow/subs');
      await dir.create(recursive: true);
      final epTag = 'E${rec.episodeNumber?.toInt() ?? ''}';
      final saved = <OfflineSubtitle>[];
      var idx = 0;
      for (final sub in source.subtitles) {
        idx++;
        try {
          final path =
              '${dir.path}/${safeShow}_${epTag}_${_safe(sub.lang)}_$idx'
              '${_subExt(sub.url, sub.format)}';
          final resp = await _dio.get<List<int>>(
            sub.url,
            options: Options(
              responseType: ResponseType.bytes,
              headers: source.headers,
            ),
          );
          final bytes = resp.data;
          if (bytes == null || bytes.isEmpty) continue;
          await File(path).writeAsBytes(bytes, flush: true);
          saved.add(
            OfflineSubtitle(
              lang: sub.lang,
              label: sub.label,
              path: path,
              isDefault: sub.isDefault,
            ),
          );
        } catch (_) {/* skip this track */}
      }
      if (saved.isEmpty) return;
      // Re-read: the download may have been canceled/deleted while we fetched.
      final cur = _records[rec.id];
      if (cur == null || cur.status == DownloadStatus.canceled) {
        for (final s in saved) {
          try {
            await File(s.path).delete();
          } catch (_) {}
        }
        return;
      }
      _put(cur.copyWith(subtitles: saved));
      notifyListeners();
    } catch (_) {/* no subtitles offline — non-fatal */}
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  Future<void> pause(DownloadRecord rec) async {
    final t = _tasks[rec.id];
    if (t != null) await _dl.pause(t);
  }

  Future<void> resume(DownloadRecord rec) async {
    final t = _tasks[rec.id];
    if (t != null) {
      await _dl.resume(t);
    } else {
      // Task object lost (e.g. after restart) — re-resolve and enqueue.
      await _resolveAndEnqueue(rec.copyWith(status: DownloadStatus.queued));
    }
  }

  Future<void> cancel(DownloadRecord rec) async {
    _candidates.remove(rec.id); // user stopped it — don't auto-advance mirrors
    // Mark canceled FIRST so any in-flight resolve/update sees it and bails
    // (otherwise a resolve finishing after cancel would re-enqueue, leaving the
    // tile stuck "loading" despite saying canceled).
    _put(rec.copyWith(status: DownloadStatus.canceled, progress: 0));
    notifyListeners();
    try {
      await _dl.cancelTaskWithId(rec.id); // direct-file task (if any)
    } catch (_) {}
    DownloadService.instance.invoke('cancel', {'id': rec.id}); // HLS job (if any)
    _tasks.remove(rec.id);
  }

  bool _isCanceled(String id) =>
      _records[id]?.status == DownloadStatus.canceled ||
      !_records.containsKey(id); // deleted

  /// Cancel (if active) and forget the record + delete the saved file.
  Future<void> delete(DownloadRecord rec) async {
    _candidates.remove(rec.id);
    try {
      await _dl.cancelTaskWithId(rec.id);
    } catch (_) {}
    DownloadService.instance.invoke('cancel', {'id': rec.id}); // stop HLS job
    _tasks.remove(rec.id);
    // Remove any saved subtitle sidecar files too.
    for (final s in rec.subtitles) {
      try {
        final f = File(s.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _records.remove(rec.id);
    await _box.delete(rec.id);
    notifyListeners();
  }

  // ── Update stream ──────────────────────────────────────────────────────────

  Future<void> _onUpdate(TaskUpdate update) async {
    final id = update.task.taskId;
    final rec = _records[id];
    if (rec == null) return;
    // Ignore late updates for a download the user canceled/deleted, so a
    // trailing progress/running event can't flip it back to "downloading".
    if (rec.status == DownloadStatus.canceled) return;

    if (update is TaskProgressUpdate) {
      if (update.progress >= 0) {
        _put(
          rec.copyWith(
            status: DownloadStatus.downloading,
            progress: update.progress,
            bytesTotal: update.expectedFileSize > 0
                ? update.expectedFileSize
                : null,
          ),
        );
        notifyListeners();
      }
      return;
    }

    if (update is TaskStatusUpdate) {
      switch (update.status) {
        case TaskStatus.enqueued:
          _put(rec.copyWith(status: DownloadStatus.queued));
        case TaskStatus.running:
          _put(rec.copyWith(status: DownloadStatus.downloading));
        case TaskStatus.paused:
          _put(rec.copyWith(status: DownloadStatus.paused));
        case TaskStatus.complete:
          await _finish(rec, update.task as DownloadTask, update.mimeType);
        case TaskStatus.canceled:
          _put(rec.copyWith(status: DownloadStatus.canceled));
        case TaskStatus.notFound:
        case TaskStatus.failed:
          if (await _tryNext(rec)) return; // fall through to the next mirror
          _put(
            rec.copyWith(
              status: DownloadStatus.failed,
              error: () => update.exception?.description ?? 'Download failed',
            ),
          );
        case TaskStatus.waitingToRetry:
          _put(rec.copyWith(status: DownloadStatus.downloading));
      }
      notifyListeners();
    }
  }

  Future<void> _finish(
    DownloadRecord rec,
    DownloadTask task,
    String? mimeType,
  ) async {
    // Content guard: if the server handed back a web/landing page instead of a
    // video (the 4khdhub HubCloud/gamerxyt case), don't keep it.
    final mt = (mimeType ?? '').toLowerCase();
    final looksHtml = mt.contains('html') || mt.startsWith('text/');
    int size = 0;
    try {
      final f = File(await task.filePath());
      if (await f.exists()) size = await f.length();
      if (looksHtml || (size > 0 && size < 524288)) {
        // <512KB or HTML → not a real video file; bin it and try the next
        // mirror before giving up.
        if (await f.exists()) await f.delete();
        if (await _tryNext(rec)) return;
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () => 'That server returned a web page, not a video — '
                'try a different server',
          ),
        );
        return;
      }
    } catch (_) {}

    String? path;
    try {
      path = await _dl.moveToSharedStorage(
        task,
        SharedStorage.downloads,
        directory: '$_sharedDir/${_safe(rec.showTitle)}',
      );
    } catch (_) {}
    // Fall back to the app-documents path if the move failed.
    path ??= await task.filePath();
    _candidates.remove(rec.id); // success — no more fallbacks needed
    _put(
      rec.copyWith(
        status: DownloadStatus.done,
        progress: 1,
        filePath: () => path,
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _put(DownloadRecord rec) {
    _records[rec.id] = rec;
    _box.put(rec.id, rec.toMap());
  }

  /// Deterministic record id. Includes the SHOW id because providers like
  /// AllAnime reuse episode ids ('sub:1', 'sub:2', …) across every show — so
  /// without the show id, episode 1 of one anime collides with episode 1 of
  /// another and the second download gets skipped.
  String _idFor(String sourceId, String showId, String episodeId) =>
      _safe('${sourceId}_${showId}_$episodeId');

  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  /// File extension (incl. dot) from a url path, defaulting to .mp4.
  static String _ext(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    for (final e in const ['.mp4', '.mkv', '.webm', '.mov', '.m4v']) {
      if (path.endsWith(e)) return e;
    }
    return '.mp4';
  }

  /// Subtitle file extension (incl. dot) from the url, then the declared
  /// [format], defaulting to .vtt.
  static String _subExt(String url, String? format) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    for (final e in const ['.vtt', '.srt', '.ass', '.ssa', '.sub']) {
      if (path.endsWith(e)) return e;
    }
    final f = (format ?? '').toLowerCase();
    if (f.contains('srt')) return '.srt';
    if (f.contains('ass')) return '.ass';
    if (f.contains('ssa')) return '.ssa';
    return '.vtt';
  }

  /// HLS sources route through the in-app segment downloader; everything else
  /// through background_downloader.
  static bool _isHls(VideoSource s) {
    if (s.container == SourceContainer.hls) return true;
    return (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase().endsWith('.m3u8');
  }

  static int _height(VideoSource s) {
    final m = RegExp(r'(\d{3,4})').firstMatch(s.quality ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// All sources (HLS + direct, both downloadable now) ordered for the requested
  /// quality. 'best' = highest first; otherwise by CLOSENESS to the requested
  /// height (so 360p gets the smallest file) — ties go to the higher quality.
  /// The full ordered list doubles as the try-next fallback.
  static List<VideoSource> _ranked(List<VideoSource> sources, String quality) {
    final list = List<VideoSource>.from(sources);
    if (list.isEmpty) return const [];
    if (quality == 'best') {
      list.sort((a, b) => _height(b).compareTo(_height(a)));
      return list;
    }
    final want =
        int.tryParse(RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1) ?? '');
    if (want == null) {
      list.sort((a, b) => _height(b).compareTo(_height(a)));
      return list;
    }
    list.sort((a, b) {
      final da = (_height(a) - want).abs();
      final db = (_height(b) - want).abs();
      if (da != db) return da.compareTo(db); // closest to requested first
      return _height(b).compareTo(_height(a)); // tie → higher quality
    });
    return list;
  }
}
