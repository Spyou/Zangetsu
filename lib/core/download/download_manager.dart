import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/episode.dart';
import '../models/video_source.dart';
import '../repository/source_repository.dart';
import 'download_record.dart';

/// Owns offline downloads: resolves a direct-file source per episode, enqueues
/// a background download, tracks progress, and moves the finished file into the
/// public Downloads folder. Records persist in the Hive `downloads` box so the
/// library survives restarts. A [ChangeNotifier] so the UI can rebuild live.
///
/// Phase 1 handles direct-file (MP4/MKV) sources only; HLS-only episodes are
/// marked [DownloadStatus.unsupported]. See docs/downloads-feature.md.
class DownloadManager extends ChangeNotifier {
  DownloadManager(this._repo);

  final SourceRepository _repo;

  static const String boxName = 'downloads';
  static const String _sharedDir = 'Zangetsu';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  final FileDownloader _dl = FileDownloader();

  /// In-memory cache of records, keyed by id (mirrors the Hive box).
  final Map<String, DownloadRecord> _records = {};
  // Live DownloadTask objects for in-session control (pause/resume/move).
  final Map<String, DownloadTask> _tasks = {};
  StreamSubscription<TaskUpdate>? _sub;

  /// Wire notifications + the update stream. Call once at app start.
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

  DownloadRecord? recordFor(String sourceId, String episodeId) =>
      _records[_idFor(sourceId, episodeId)];

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
  }) async {
    // Best-effort notification permission so the progress notification shows.
    try {
      await Permission.notification.request();
    } catch (_) {}

    final pending = <DownloadRecord>[];
    for (final ep in episodes) {
      final id = _idFor(sourceId, ep.id);
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

  Future<void> _resolveAndEnqueue(DownloadRecord rec) async {
    _put(rec.copyWith(status: DownloadStatus.resolving));
    notifyListeners();
    try {
      final sources = await _repo.sources(rec.episodeUrl, sourceId: rec.sourceId);
      final picked = _pick(sources, rec.quality);
      if (picked == null) {
        _put(
          rec.copyWith(
            status: DownloadStatus.unsupported,
            error: () => 'No downloadable (non-HLS) source',
          ),
        );
        notifyListeners();
        return;
      }
      final task = DownloadTask(
        taskId: rec.id,
        url: picked.url,
        filename: '${_safe(rec.showTitle)}_E${rec.episodeNumber?.toInt() ?? ''}'
            '_${_safe(rec.quality)}${_ext(picked.url)}',
        headers: picked.headers ?? const {},
        directory: '$_sharedDir/${_safe(rec.showTitle)}',
        baseDirectory: BaseDirectory.applicationDocuments,
        updates: Updates.statusAndProgress,
        allowPause: true,
        displayName: '${rec.showTitle} · E${rec.episodeNumber?.toInt() ?? ''}',
      );
      _tasks[rec.id] = task;
      final ok = await _dl.enqueue(task);
      if (!ok) {
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () => "Couldn't start download",
          ),
        );
        notifyListeners();
      }
    } catch (e) {
      _put(
        rec.copyWith(status: DownloadStatus.failed, error: () => 'Resolve failed'),
      );
      notifyListeners();
    }
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
    await _dl.cancelTaskWithId(rec.id);
    _put(rec.copyWith(status: DownloadStatus.canceled));
    notifyListeners();
  }

  /// Cancel (if active) and forget the record + delete the saved file.
  Future<void> delete(DownloadRecord rec) async {
    try {
      await _dl.cancelTaskWithId(rec.id);
    } catch (_) {}
    _tasks.remove(rec.id);
    _records.remove(rec.id);
    await _box.delete(rec.id);
    notifyListeners();
  }

  // ── Update stream ──────────────────────────────────────────────────────────

  Future<void> _onUpdate(TaskUpdate update) async {
    final id = update.task.taskId;
    final rec = _records[id];
    if (rec == null) return;

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
          await _finish(rec, update.task as DownloadTask);
        case TaskStatus.canceled:
          _put(rec.copyWith(status: DownloadStatus.canceled));
        case TaskStatus.notFound:
        case TaskStatus.failed:
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

  Future<void> _finish(DownloadRecord rec, DownloadTask task) async {
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

  String _idFor(String sourceId, String episodeId) =>
      _safe('${sourceId}_$episodeId');

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

  static bool _isDirectFile(VideoSource s) {
    if (s.container == SourceContainer.hls) return false;
    final path = (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase();
    if (path.endsWith('.m3u8')) return false;
    if (s.container == SourceContainer.mp4) return true;
    return path.endsWith('.mp4') ||
        path.endsWith('.mkv') ||
        path.endsWith('.webm') ||
        path.endsWith('.mov') ||
        path.endsWith('.m4v');
  }

  static int _height(VideoSource s) {
    final m = RegExp(r'(\d{3,4})').firstMatch(s.quality ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// Best direct-file source matching the requested quality; falls back to the
  /// highest available direct-file source. Null when none are direct-file.
  static VideoSource? _pick(List<VideoSource> sources, String quality) {
    final direct = sources.where(_isDirectFile).toList();
    if (direct.isEmpty) return null;
    direct.sort((a, b) => _height(b).compareTo(_height(a)));
    if (quality == 'best') return direct.first;
    final want = int.tryParse(RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1) ?? '');
    if (want != null) {
      for (final s in direct) {
        if (_height(s) == want) return s;
      }
    }
    return direct.first; // requested tier absent → best available
  }
}
