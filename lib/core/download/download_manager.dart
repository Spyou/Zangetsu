import 'dart:async';
import 'package:watch_app/core/hive/safe_box.dart';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../logging/app_logger.dart';
import '../models/episode.dart';
import '../models/video_source.dart';
import '../repository/source_repository.dart';
import '../torrent/torrent_download_service.dart';
import '../torrent/torrent_prefs.dart';
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
  DownloadManager(this._repo,
      [DownloadPrefs? downloadPrefs, TorrentDownloadService? torrentSvc])
      : _downloadPrefs = downloadPrefs ?? DownloadPrefs(),
        _torrentSvc = torrentSvc ?? TorrentDownloadService();

  final SourceRepository _repo;
  final DownloadPrefs _downloadPrefs;
  final TorrentDownloadService _torrentSvc;

  /// Latest torrent-download progress per id (peers/speed for the UI), kept
  /// out of [DownloadRecord] so it isn't persisted every tick.
  final Map<String, TorrentDownloadProgress> torrentProgress = {};

  static const String boxName = 'downloads';
  static const String _sharedDir = 'Zangetsu';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  final FileDownloader _dl = FileDownloader();
  // Throttles direct-file (MP4) downloads to the "Parallel downloads" setting.
  // background_downloader runs enqueued tasks concurrently, so without this the
  // limit was silently HLS-only. The queue holds extras until a slot frees.
  final MemoryTaskQueue _mp4Queue = MemoryTaskQueue();
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
    // Route MP4 downloads through the concurrency-limited queue.
    _mp4Queue.maxConcurrent = _downloadPrefs.parallelDownloads;
    _dl.addTaskQueue(_mp4Queue);
    // A task the queue couldn't enqueue at all (rare) → same fallback as a
    // failed start: try the next mirror, else mark failed.
    _mp4Queue.enqueueErrors.listen((task) async {
      final rec = _records[task.taskId];
      if (rec == null || rec.status == DownloadStatus.canceled) return;
      AppLogger.instance.log(
        "[download] MP4 couldn't enqueue — ${rec.showTitle} · "
        '${rec.episodeTitle} [${rec.quality}]',
        level: 'E',
      );
      if (await _tryNext(rec)) return;
      _put(rec.copyWith(
        status: DownloadStatus.failed,
        error: () => "Couldn't start download",
      ));
      notifyListeners();
    });
    _listenBackgroundService();
    _listenTorrentDownloads();
    _reconcileServiceResults(); // apply HLS downloads finished while killed
  }

  /// Apply a new "Parallel downloads" limit live to BOTH paths — the MP4 queue
  /// here and the HLS service — so a change takes effect on the current batch.
  /// Raising it starts queued episodes right away; lowering it only stops new
  /// ones spawning (running downloads are never interrupted).
  void setParallel(int n) {
    final v = n.clamp(DownloadPrefs.parallelMin, DownloadPrefs.parallelMax);
    _mp4Queue.maxConcurrent = v;
    // The queue only re-checks on add/finish, not when maxConcurrent changes —
    // so nudge it, otherwise raising the limit wouldn't start queued downloads
    // until the current one ended.
    _mp4Queue.advanceQueue();
    DownloadService.instance.invoke('setParallel', {'n': v});
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
    svc.on('done').listen((d) async {
      final id = d?['id'] as String?;
      if (id == null) return;
      final rec = _records[id];
      if (rec == null) return;
      _candidates.remove(id);
      var path = d?['filePath'] as String?;
      // The isolate handed back the local .ts temp; remux it to a real .mp4
      // (Android) and move it into shared storage / the user's SAF folder here.
      if (path != null && d?['needsFinalize'] == true) {
        final finalized = await _finalizeHls(
          path,
          customUri: d?['customUri'] as String?,
          subDir: d?['sharedSubDir'] as String?,
        );
        if (finalized != null) path = finalized;
      }
      await _markDone(rec, path);
      notifyListeners();
    });
    svc.on('failed').listen((d) async {
      final id = d?['id'] as String?;
      if (id == null) return;
      final rec = _records[id];
      if (rec == null || d?['canceled'] == true) return;
      final err = d?['error'] as String? ?? 'Download failed';
      AppLogger.instance.log(
        '[download] HLS failed — ${rec.showTitle} · ${rec.episodeTitle} '
        '[${rec.quality}]: $err',
        level: 'E',
      );
      if (await _tryNext(rec)) return; // fell back to another mirror
      _put(rec.copyWith(
        status: DownloadStatus.failed,
        error: () => err,
      ));
      notifyListeners();
    });
  }

  /// Apply progress events from the native torrent download engine onto records
  /// (peers/speed are cached in [torrentProgress] for the UI).
  void _listenTorrentDownloads() {
    _torrentSvc.events().listen((p) async {
      final rec = _records[p.id];
      if (rec == null || rec.status == DownloadStatus.canceled) return;
      torrentProgress[p.id] = p;
      switch (p.status) {
        case 'done':
          _candidates.remove(p.id);
          await _markDone(rec, p.filePath);
        case 'failed':
          _put(rec.copyWith(
            status: DownloadStatus.failed,
            error: () => p.error ?? 'Torrent download failed',
          ));
        case 'paused':
          _put(rec.copyWith(status: DownloadStatus.paused));
        default: // queued | downloading | copying — keep it "downloading"
          _put(rec.copyWith(
            status: DownloadStatus.downloading,
            progress: p.progress,
          ));
      }
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
              var path = m['filePath'] as String?;
              // App was killed before the live finalize ran — remux + move now.
              if (path != null && m['needsFinalize'] == true) {
                final finalized = await _finalizeHls(
                  path,
                  customUri: m['customUri'] as String?,
                  subDir: m['sharedSubDir'] as String?,
                );
                if (finalized != null) path = finalized;
              }
              await _markDone(rec, path);
            } else if (status == 'failed') {
              final err = m['error'] as String? ?? 'Download failed';
              AppLogger.instance.log(
                '[download] HLS failed (finished offline) — '
                '${rec.showTitle} · ${rec.episodeTitle}: $err',
                level: 'E',
              );
              _put(rec.copyWith(
                status: DownloadStatus.failed,
                error: () => err,
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
    // Carry the outgoing file on the new record so it survives a restart —
    // in memory it was lost if the app died mid re-download, stranding the old
    // file for good. A previous supersededPath wins if this record never got a
    // file of its own (a re-download that failed, then was retried).
    final replacing = _records[_idFor(sourceId, showId, episode.id)];
    final outgoing = (replacing?.filePath?.isNotEmpty ?? false)
        ? replacing!.filePath
        : replacing?.supersededPath;
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
      supersededPath: outgoing,
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
        AppLogger.instance.log(
          '[download] no downloadable source — ${rec.showTitle} · '
          '${rec.episodeTitle} (${sources.length} source(s), all HLS/unusable)',
          level: 'E',
        );
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
      AppLogger.instance
          .log('download resolve failed (${rec.showTitle}): $e', level: 'E');
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
    if (isTorrentSource(source)) {
      await _startTorrentDownload(rec, source);
      return;
    }
    final filename =
        '${_safe(rec.showTitle)}_E${rec.episodeNumber?.toInt() ?? ''}'
        '_${_safe(rec.quality)}${_ext(source.url)}';
    final displayName =
        '${rec.showTitle} · E${rec.episodeNumber?.toInt() ?? ''}';
    final headers = source.headers ?? const <String, String>{};
    // Flaky file hosts (4khdhub's HubCloud/gamerxyt CDN) drop the connection
    // mid-transfer. retries + allowPause let background_downloader RESUME from
    // the partial (the host supports range — mpv can seek it) on each drop
    // instead of restarting from 0. waitingToRetry / negative retry-progress
    // are already handled in _onUpdate, so this only adds resilience.
    // A picked SAF folder (content://) streams straight into that tree. A
    // detected drive (a plain volume path) or the default both download to
    // app-docs first — _finish then moves a drive download onto the volume.
    final loc = _downloadPrefs.locationUri;
    final safUri = loc != null && loc.isNotEmpty && isUriPath(loc) ? loc : null;
    final DownloadTask task = safUri != null
        // Custom SAF folder: stream straight into the user's picked directory
        // (the file ends up as a content:// URI — see _finish). No post-move.
        ? UriDownloadTask(
            taskId: rec.id,
            url: source.url,
            filename: filename,
            headers: headers,
            directoryUri: Uri.parse(safUri),
            updates: Updates.statusAndProgress,
            retries: 5,
            allowPause: true,
            displayName: displayName,
          )
        : DownloadTask(
            taskId: rec.id,
            url: source.url,
            filename: filename,
            headers: headers,
            directory: '$_sharedDir/${_safe(rec.showTitle)}',
            baseDirectory: BaseDirectory.applicationDocuments,
            updates: Updates.statusAndProgress,
            retries: 5,
            allowPause: true,
            displayName: displayName,
          );
    _tasks[rec.id] = task;
    // Mark it waiting ("Queued"); the queue enqueues it when a parallel slot is
    // free (→ enqueued/running in _onUpdate). Start failures come back via
    // _mp4Queue.enqueueErrors + _onUpdate's failed case.
    _put(rec.copyWith(status: DownloadStatus.queued, progress: 0));
    notifyListeners();
    _mp4Queue.add(task);
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
      // Download the concatenated TS to a local temp with an honest .ts name;
      // the main isolate finalizes it (remux → real .mp4 on Android, else keep
      // the .ts) once the service reports done — see _finalizeHls.
      final outputPath =
          '${dir.path}/${safeShow}_E${rec.episodeNumber?.toInt() ?? ''}'
          '_${_safe(rec.quality)}.ts';

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
        // Custom SAF folder (if any): the isolate can't SAF-write, so it hands
        // the local temp back and the main isolate moves it into this tree.
        'customUri': _downloadPrefs.locationUri,
        // How many episodes run at once + segment connections per download.
        'parallel': _downloadPrefs.parallelDownloads,
        'connections': _downloadPrefs.connectionsPerDownload,
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

  /// Native TS→MP4 remux channel (Android only). See MainActivity + TsRemuxer.
  static const MethodChannel _downloadChannel =
      MethodChannel('zangetsu/download');

  /// Remux the concatenated-TS file at [input] into a real MP4 at [output] via
  /// the native MediaMuxer (stream-copy). Returns true on success; false on
  /// non-Android and on any native failure, so callers fall back to a `.ts`.
  Future<bool> _remuxToMp4(String input, String output) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _downloadChannel.invokeMethod<bool>(
        'remuxTsToMp4',
        {'input': input, 'output': output},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Storage volumes downloads can target WITHOUT the SAF picker (internal +
  /// any USB/SSD/SD drive), for the TV location picker. Each is a plain
  /// app-specific external path stored as the download location. Android only;
  /// empty elsewhere.
  Future<List<({String path, String label, bool removable})>>
      listDownloadVolumes() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _downloadChannel
          .invokeMethod<List<dynamic>>('listDownloadVolumes');
      if (raw == null) return const [];
      return raw.map((e) {
        final m = (e as Map).cast<String, dynamic>();
        return (
          path: m['path'] as String,
          label: (m['label'] as String?) ?? 'Storage',
          removable: (m['removable'] as bool?) ?? false,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Finalizes an HLS download the isolate left as a local `.ts` temp: on Android
  /// remux it into a real, seekable `.mp4` (falling back to the `.ts` if the
  /// remux can't handle the stream); iOS keeps the `.ts` (no MediaMuxer, and mpv
  /// plays a correctly-named `.ts` fine — the frame-skipping was purely the old
  /// `.mp4` mislabel). Then move the result into the custom SAF folder or public
  /// Downloads. Returns the final stored path (or the local one on move failure).
  Future<String?> _finalizeHls(
    String tsPath, {
    String? customUri,
    String? subDir,
  }) async {
    final dir = subDir ?? _sharedDir;
    // A detected drive is a plain volume path (not a content:// SAF tree) — an
    // app-specific external dir we can write to with plain File I/O. Remux the
    // .ts into a real .mp4 STRAIGHT onto the volume, avoiding a big post-move.
    final isVolume =
        customUri != null && customUri.isNotEmpty && !isUriPath(customUri);
    if (isVolume && Platform.isAndroid) {
      try {
        final destDir = Directory('$customUri/$dir');
        await destDir.create(recursive: true);
        final mp4 = '${destDir.path}/${_withExt(tsPath.split('/').last, 'mp4')}';
        if (await _remuxToMp4(tsPath, mp4)) {
          try {
            await File(tsPath).delete();
          } catch (_) {}
          return mp4;
        }
        // Remux couldn't handle the stream → keep the .ts, on the volume.
        return await _moveToVolume(tsPath, customUri, dir) ?? tsPath;
      } catch (_) {
        return tsPath; // volume write failed → keep the local temp
      }
    }
    if (isVolume) {
      // iOS (no MediaMuxer): just move the .ts onto the chosen location.
      return await _moveToVolume(tsPath, customUri, dir) ?? tsPath;
    }

    // ── Picked SAF folder / default public Downloads (unchanged) ──
    var publish = tsPath; // already an honest .ts
    if (Platform.isAndroid) {
      final mp4 = _withExt(tsPath, 'mp4');
      final remuxed = mp4 != tsPath && await _remuxToMp4(tsPath, mp4);
      debugPrint('[dl] HLS finalize: ${remuxed ? 'remuxed to mp4' : 'kept .ts'}');
      if (remuxed) {
        publish = mp4;
        try {
          await File(tsPath).delete();
        } catch (_) {}
      }
      // Remux failed on an odd stream → keep the honestly-labelled .ts.
    }
    if (customUri != null && customUri.isNotEmpty) {
      final moved =
          await _moveIntoTree(publish, customUri, publish.split('/').last);
      return moved ?? publish;
    }
    try {
      final moved = await _dl.moveFileToSharedStorage(
        publish,
        SharedStorage.downloads,
        directory: dir,
      );
      return moved ?? publish;
    } catch (_) {
      return publish;
    }
  }

  /// Move a finished local file onto a detected drive (a plain app-specific
  /// external volume path — USB/SSD/SD). Cross-filesystem, so copy+delete
  /// (rename fails across mounts). Returns the new path, or null on failure so
  /// the caller keeps the local copy.
  Future<String?> _moveToVolume(
    String localPath,
    String volumeBase,
    String subDir,
  ) async {
    try {
      final dir = Directory('$volumeBase/$subDir');
      await dir.create(recursive: true);
      final dest = '${dir.path}/${localPath.split('/').last}';
      await File(localPath).copy(dest);
      try {
        await File(localPath).delete();
      } catch (_) {}
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// [path] with its extension swapped to [ext] (e.g. `foo.ts` → `foo.mp4`).
  String _withExt(String path, String ext) {
    final slash = path.lastIndexOf('/');
    final dot = path.lastIndexOf('.');
    final base = dot > slash ? path.substring(0, dot) : path;
    return '$base.$ext';
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
    if (rec.isTorrent) {
      try {
        await _torrentSvc.pause(rec.id);
      } catch (_) {}
      _put(rec.copyWith(status: DownloadStatus.paused));
      notifyListeners();
      return;
    }
    final t = _tasks[rec.id];
    if (t != null) await _dl.pause(t);
  }

  Future<void> resume(DownloadRecord rec) async {
    if (rec.isTorrent) {
      try {
        await _torrentSvc.resume(rec.id);
      } catch (_) {}
      _put(rec.copyWith(status: DownloadStatus.downloading));
      notifyListeners();
      return;
    }
    final t = _tasks[rec.id];
    if (t != null) {
      await _dl.resume(t);
    } else {
      // Task object lost (e.g. after restart) — re-resolve and enqueue.
      await _resolveAndEnqueue(rec.copyWith(status: DownloadStatus.queued));
    }
  }

  /// Re-download a failed record from scratch: forget any stale mirror list,
  /// clear the error, and resolve a fresh source. No-op for done/active
  /// downloads and for torrents (those are re-added from the detail screen).
  Future<void> retry(DownloadRecord rec) async {
    if (rec.isTorrent || rec.status == DownloadStatus.done || rec.isActive) {
      return;
    }
    _candidates.remove(rec.id); // resolve fresh mirrors
    await _resolveAndEnqueue(
      rec.copyWith(status: DownloadStatus.queued, error: () => null),
    );
  }

  Future<void> cancel(DownloadRecord rec) async {
    _candidates.remove(rec.id); // user stopped it — don't auto-advance mirrors
    // Mark canceled FIRST so any in-flight resolve/update sees it and bails
    // (otherwise a resolve finishing after cancel would re-enqueue, leaving the
    // tile stuck "loading" despite saying canceled).
    _put(rec.copyWith(status: DownloadStatus.canceled, progress: 0));
    notifyListeners();
    if (rec.isTorrent) {
      try {
        await _torrentSvc.cancel(rec.id);
      } catch (_) {}
      torrentProgress.remove(rec.id);
      _tasks.remove(rec.id);
      return;
    }
    _mp4Queue.removeTasksWithIds([rec.id]); // drop it if still waiting in line
    try {
      await _dl.cancelTaskWithId(rec.id); // direct-file task (if enqueued/running)
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
    if (rec.isTorrent) {
      try {
        await _torrentSvc.cancel(rec.id);
      } catch (_) {}
      torrentProgress.remove(rec.id);
    }
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
    // Delete the actual media file on disk. Two cases:
    //  • SAF custom folder → a content:// URI, removed via UriUtils.
    //  • Default download (public Download/Zangetsu) → a plain file path the
    //    app owns. Previously ONLY the content:// case was handled, so default
    //    downloads left the file on disk (the "still in the folder" bug). Delete
    //    it directly; if scoped storage blocks the raw delete, fall back to the
    //    plugin's native (MediaStore-aware) delete. Then drop the empty show dir.
    await _deleteMediaFile(rec.filePath);
    // A re-download that never finished leaves the file it was going to
    // replace pointed at here; it has no other owner, so it goes too.
    if (rec.supersededPath != rec.filePath) {
      await _deleteMediaFile(rec.supersededPath);
    }
    _records.remove(rec.id);
    await _box.delete(rec.id);
    notifyListeners();
  }

  /// Delete every download in [recs] — a whole show group in one go. Cancels
  /// active ones, removes the records + files. Best-effort per item (one
  /// failure never blocks the rest); snapshots first since [delete] mutates the
  /// record map as it goes.
  Future<void> deleteAll(Iterable<DownloadRecord> recs) async {
    for (final r in recs.toList()) {
      try {
        await delete(r);
      } catch (_) {}
    }
    notifyListeners();
  }

  static const MethodChannel _deviceChannel = MethodChannel(
    'com.spyou.watch_app/device',
  );

  /// Does a SAF `content://` download still exist? Checked natively via
  /// DocumentFile (Dart can't stat a content:// URI). Returns true on any
  /// uncertainty so a valid download is never wrongly pruned.
  Future<bool> _documentExists(String uri) async {
    try {
      final r = await _deviceChannel.invokeMethod<bool>('documentExists', {
        'uri': uri,
      });
      return r ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Byte size of a SAF content:// document (-1 if unknown), via native
  /// DocumentFile — Dart can't stat a content:// URI.
  Future<int> _documentSize(String uri) async {
    try {
      final r = await _deviceChannel.invokeMethod<int>('documentSize', {
        'uri': uri,
      });
      return r ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Move a finished local file into a user-picked SAF tree (via native
  /// DocumentFile — works without a foreground activity). Returns the new
  /// content:// URI, or null on failure so the caller keeps the local path.
  Future<String?> _moveIntoTree(
    String localPath,
    String treeUri,
    String filename,
  ) async {
    try {
      return await _deviceChannel.invokeMethod<String>('moveIntoTree', {
        'localPath': localPath,
        'treeUri': treeUri,
        'filename': filename,
      });
    } catch (_) {
      return null;
    }
  }

  /// Reconcile the list with disk: drop `done` records whose file was removed
  /// OUTSIDE the app (a file manager), so the UI can't show phantom downloads.
  /// Handles BOTH default downloads (plain file path — a cheap `exists` syscall)
  /// and custom-folder SAF downloads (content:// — via native DocumentFile).
  /// Skips in-flight records; emits a single [notifyListeners] if anything went.
  Future<void> pruneMissing() async {
    final gone = <String>[];
    // Downloads that finished before the size was recorded on completion. They
    // sat at "0 B" forever and dragged the storage total down with them, so
    // measure them here — this already stats every file, so it costs nothing
    // extra. Collected and applied after the loop rather than written inline,
    // to avoid mutating the map being iterated.
    final measured = <DownloadRecord>[];
    for (final rec in _records.values) {
      if (rec.status != DownloadStatus.done) continue;
      final fp = rec.filePath;
      if (fp == null || fp.isEmpty) continue;
      try {
        if (isUriPath(fp)) {
          if (!await _documentExists(fp)) gone.add(rec.id);
          continue;
        }
        final f = File(fp);
        if (await f.exists()) {
          if (rec.bytesTotal <= 0) {
            final len = await sizeOf(fp);
            if (len != null) measured.add(rec.copyWith(bytesTotal: len));
          }
          continue; // file present → keep
        }
        // Storage is "available" if ANY ancestor dir still exists (walk up), so
        // a missing file means it was deleted — not that the volume is unmounted.
        var storageOk = false;
        var d = f.parent;
        for (var i = 0; i < 8; i++) {
          if (await d.exists()) {
            storageOk = true;
            break;
          }
          final up = d.parent;
          if (up.path == d.path) break;
          d = up;
        }
        if (storageOk) gone.add(rec.id);
      } catch (_) {}
    }
    if (measured.isNotEmpty) {
      for (final rec in measured) {
        _put(rec);
      }
      notifyListeners();
    }
    if (gone.isEmpty) return;
    for (final id in gone) {
      _records.remove(id);
      _candidates.remove(id);
      _tasks.remove(id);
      await _box.delete(id);
    }
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
          AppLogger.instance.log(
            '[download] MP4 ${update.status.name} — ${rec.showTitle} · '
            '${rec.episodeTitle} [${rec.quality}]: '
            '${update.exception?.description ?? 'no detail'}',
            level: 'E',
          );
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
    String? path;

    if (task is UriDownloadTask) {
      // Custom-folder download: the file streamed straight into the user's
      // picked SAF folder, so it's already published as a content:// URI.
      path = task.fileUri?.toString();
      if (path == null) {
        if (await _tryNext(rec)) return;
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () => "Couldn't save to the chosen folder",
          ),
        );
        notifyListeners();
        return;
      }
      // Same content-guard as the default path, but via a native size check
      // (Dart can't stat content://). A tiny file is a stub, NOT a video — e.g.
      // MovieBox streams DASH and hands back a ~95 KB `.mpd` manifest. Bin it and
      // try the next mirror; only reject on a CONFIDENT small size (>0), so an
      // unknown size (-1) never discards a real download.
      final size = await _documentSize(path);
      if (size > 0 && size < 524288) {
        try {
          await _dl.uri.deleteFile(Uri.parse(path));
        } catch (_) {}
        if (await _tryNext(rec)) return;
        _put(
          rec.copyWith(
            status: DownloadStatus.failed,
            error: () => "This source can't be downloaded (stream-only / DASH) — "
                'try a different server',
          ),
        );
        notifyListeners();
        return;
      }
    } else {
      // Content guard: if the server handed back a web/landing page instead of
      // a video (the 4khdhub HubCloud/gamerxyt case), don't keep it.
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

      final subDir = '$_sharedDir/${_safe(rec.showTitle)}';
      final loc = _downloadPrefs.locationUri;
      if (loc != null && loc.isNotEmpty && !isUriPath(loc)) {
        // Detected drive (USB/SSD/SD): move the file onto that volume.
        path = await _moveToVolume(await task.filePath(), loc, subDir);
      } else {
        try {
          path = await _dl.moveToSharedStorage(
            task,
            SharedStorage.downloads,
            directory: subDir,
          );
        } catch (_) {}
      }
      // Fall back to the app-documents path if the move failed.
      path ??= await task.filePath();
    }

    _candidates.remove(rec.id); // success — no more fallbacks needed
    await _markDone(rec, path);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Delete a downloaded media file. Two cases:
  ///  • SAF custom folder → a content:// URI, removed via UriUtils.
  ///  • Default download (public Download/Zangetsu) → a plain file path the
  ///    app owns. Previously ONLY the content:// case was handled, so default
  ///    downloads left the file on disk (the "still in the folder" bug). Delete
  ///    it directly; if scoped storage blocks the raw delete, fall back to the
  ///    plugin's native (MediaStore-aware) delete. Then drop the empty show dir.
  Future<void> _deleteMediaFile(String? fp) async {
    if (fp == null || fp.isEmpty) return;
    try {
      if (isUriPath(fp)) {
        await _dl.uri.deleteFile(Uri.parse(fp));
      } else {
        final f = File(fp);
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
        if (await f.exists()) {
          try {
            await _dl.uri.deleteFile(f.uri);
          } catch (_) {}
        }
        try {
          final dir = f.parent;
          if (await dir.exists() && await dir.list().isEmpty) {
            await dir.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Size of a finished download, or null to leave what's already recorded.
  ///
  /// Only the background_downloader path reports a size (via
  /// `expectedFileSize`), so HLS — which is fetched in-app and remuxed — always
  /// finished at 0 and the storage total under-counted every anime source.
  /// A content:// URI can't be stat'd, so those keep whatever they had.
  @visibleForTesting
  static Future<int?> sizeOf(String? path) async {
    if (path == null || path.isEmpty || isUriPath(path)) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final len = await f.length();
      return len > 0 ? len : null;
    } catch (_) {
      return null;
    }
  }

  /// Finish a download: record its real size, then clear out the file a
  /// previous download of the same episode left behind.
  ///
  /// The record id is source+show+episode with no quality or mirror in it, so
  /// re-downloading an episode at another quality overwrites the record and
  /// used to strand the old file — invisible to the app and a few hundred MB
  /// each. Deleted only once the replacement is safely on disk, so a failed
  /// re-download doesn't cost the copy that already worked.
  Future<void> _markDone(DownloadRecord rec, String? path) async {
    _put(
      rec.copyWith(
        status: DownloadStatus.done,
        progress: 1,
        filePath: () => path,
        bytesTotal: rec.bytesTotal > 0 ? null : await sizeOf(path),
        supersededPath: () => null,
      ),
    );
    final superseded = rec.supersededPath;
    if (superseded != null && superseded.isNotEmpty && superseded != path) {
      await _deleteMediaFile(superseded);
    }
  }

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

  /// Torrent (magnet/.torrent) sources route through the native torrent
  /// download engine — a distinct branch that never touches the HTTP/HLS paths.
  @visibleForTesting
  static bool isTorrentSource(VideoSource s) =>
      s.container == SourceContainer.torrent;

  Future<void> _startTorrentDownload(
      DownloadRecord rec, VideoSource source) async {
    _put(rec.copyWith(isTorrent: true, status: DownloadStatus.downloading));
    notifyListeners();
    try {
      // Torrent save-to-folder is SAF-only; a detected-drive (plain path) choice
      // isn't wired through the native torrent side yet, so fall back to default.
      final loc = _downloadPrefs.locationUri;
      await _torrentSvc.enqueue(
        rec.id,
        source.url,
        saveTreeUri: loc != null && isUriPath(loc) ? loc : null,
        allowMobileData: TorrentPrefs().allowMobileData,
      );
    } catch (e) {
      final wifi = e is PlatformException && e.code == 'wifi_only';
      AppLogger.instance
          .log('torrent download start failed (${rec.showTitle}): $e', level: 'E');
      _put(rec.copyWith(
        status: DownloadStatus.failed,
        error: () => wifi
            ? 'Torrents are set to Wi-Fi only (Settings › Torrents).'
            : 'Torrent download failed to start.',
      ));
      notifyListeners();
    }
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
