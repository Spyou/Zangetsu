import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/apple_tv.dart';
import 'download_prefs.dart';
import 'hls_downloader.dart';

/// Foreground-service host for HLS downloads so they continue with the app
/// backgrounded, screen off, or swiped away (Android). The UI isolate resolves
/// the m3u8 + headers and hands a job here; this isolate fetches/decrypts/
/// concatenates the segments, moves the file to public Downloads, and reports
/// progress back via [FlutterBackgroundService]. Completions are also written as
/// small result files so the UI can reconcile work finished while it was killed.
class DownloadService {
  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static FlutterBackgroundService get instance => _service;

  static const String channelId = 'zangetsu_downloads';
  static const String sharedDir = 'Zangetsu';
  static const String resultsDirName = '.results';

  /// Configure the service once at app start (does not start it).
  ///
  /// No-op on Apple TV / any platform without a registered background-service
  /// plugin — tvOS has none, and [FlutterBackgroundServicePlatform.instance]
  /// throws a string if nothing registered.
  static Future<void> initialize() async {
    if (isAppleTv) return;
    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: downloadServiceOnStart,
          autoStart: false,
          isForegroundMode: true,
          autoStartOnBoot: false,
          // Leave notificationChannelId null so the plugin creates + uses its own
          // default channel (it only auto-creates one when this is null).
          initialNotificationTitle: 'Zangetsu',
          initialNotificationContent: 'Preparing downloads…',
          foregroundServiceTypes: [AndroidForegroundType.dataSync],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: downloadServiceOnStart,
          onBackground: _iosOnBackground,
        ),
      );
    } catch (_) {
      // Unsupported platform (tvOS, desktop, tests) — downloads stay UI-bound.
    }
  }

  /// Directory where the background isolate drops completion markers.
  static Future<Directory> resultsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$sharedDir/$resultsDirName');
  }
}

@pragma('vm:entry-point')
bool _iosOnBackground(ServiceInstance service) => true;

/// Background-isolate entry point. Must be top-level + vm:entry-point.
@pragma('vm:entry-point')
void downloadServiceOnStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final dio = Dio(
    BaseOptions(
      headers: {'User-Agent': 'Mozilla/5.0 (Zangetsu) Chrome/120.0'},
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  final hls = HlsDownloader(dio);
  final queue = <Map<String, dynamic>>[];
  final canceled = <String>{};
  // How many episodes download at once (from the user's setting; last job wins).
  var parallelLimit = 3;
  // Live worker count — [pump] tops it back up to [parallelLimit] as jobs arrive.
  var running = 0;

  Future<void> setNotif(String title, String content) async {
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(title: title, content: content);
    }
  }

  // Download ONE HLS job end-to-end. Fully self-contained (its own output
  // sink + local state in [HlsDownloader]), so multiple runJob() calls are
  // safe to run concurrently.
  Future<void> runJob(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    if (canceled.remove(id)) return;

    final url = job['url'] as String;
    final headers = Map<String, String>.from(job['headers'] as Map? ?? {});
    final outputPath = job['outputPath'] as String;
    final quality = job['quality'] as String? ?? 'best';
    final label = job['label'] as String? ?? 'Episode';
    final showTitle = job['showTitle'] as String? ?? '';
    final sharedSubDir = job['sharedSubDir'] as String? ?? DownloadService.sharedDir;
    final connections = job['connections'] as int?;

    await setNotif('Downloading $showTitle', '$label · 0%');
    service.invoke('progress', {'id': id, 'progress': 0.0});

    var lastPct = -1;
    final failReason = await hls.download(
      url: url,
      headers: headers,
      outputPath: outputPath,
      preferredQuality: quality,
      connections: connections,
      onProgress: (p) {
        service.invoke('progress', {'id': id, 'progress': p});
        final pct = (p * 100).floor();
        if (pct != lastPct) {
          lastPct = pct;
          setNotif('Downloading $showTitle', '$label · $pct%');
        }
      },
      canceled: () => canceled.contains(id),
    );

    if (canceled.remove(id)) {
      await _writeResult(id, status: 'canceled');
      service.invoke('failed', {'id': id, 'canceled': true});
      return;
    }
    if (failReason != null) {
      await _writeResult(id, status: 'failed', error: failReason);
      service.invoke('failed', {'id': id, 'error': failReason});
      return;
    }

    // Hand the local temp back to the main isolate to FINALIZE: remux the
    // concatenated TS into a real MP4 (Android MediaMuxer) and move it into
    // shared storage / the user's SAF tree. Neither MediaMuxer nor the SAF/
    // MediaStore move is reachable from this background isolate.
    final customUri = job['customUri'] as String?;
    await _writeResult(
      id,
      status: 'done',
      filePath: outputPath,
      needsFinalize: true,
      customUri: customUri,
      sharedSubDir: sharedSubDir,
    );
    service.invoke('done', {
      'id': id,
      'filePath': outputPath,
      'needsFinalize': true,
      'customUri': customUri,
      'sharedSubDir': sharedSubDir,
    });
  }

  // One worker: drains queued jobs until the queue is empty, then retires.
  // removeAt(0) is synchronous, so the single-threaded isolate never hands the
  // same job to two workers.
  Future<void> workerLoop() async {
    while (queue.isNotEmpty) {
      await runJob(queue.removeAt(0));
    }
    running--;
    if (running == 0) {
      if (service is AndroidServiceInstance) {
        await service.setAsBackgroundService();
      }
      await service.stopSelf();
    }
  }

  // Spawn workers until [parallelLimit] are live (or the queue empties). Called
  // on EVERY new job, so episodes queued one-by-one still fill all the parallel
  // slots — not just the first worker.
  void pump() {
    final limit = parallelLimit.clamp(1, DownloadPrefs.parallelMax);
    while (running < limit && queue.isNotEmpty) {
      if (running == 0 && service is AndroidServiceInstance) {
        service.setAsForegroundService();
      }
      running++;
      workerLoop();
    }
  }

  service.on('download').listen((data) {
    if (data == null) return;
    final p = data['parallel'];
    if (p is int) parallelLimit = p;
    queue.add(data);
    pump();
  });
  // Live setting change: raising the limit mid-batch starts queued episodes
  // right away (pump spawns the extra workers). Lowering it just stops NEW
  // workers spawning — running downloads are never interrupted.
  service.on('setParallel').listen((data) {
    final n = data?['n'];
    if (n is int) {
      parallelLimit = n;
      pump();
    }
  });
  service.on('cancel').listen((data) {
    final id = data?['id'] as String?;
    if (id != null) canceled.add(id);
  });
  service.on('stop').listen((_) => service.stopSelf());
}

/// Persist a completion marker the UI reconciles on next launch (covers
/// downloads that finished while the app was killed).
Future<void> _writeResult(
  String id, {
  required String status,
  String? filePath,
  String? error,
  bool needsFinalize = false,
  String? customUri,
  String? sharedSubDir,
}) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docs.path}/${DownloadService.sharedDir}/${DownloadService.resultsDirName}',
    );
    await dir.create(recursive: true);
    final f = File('${dir.path}/$id.json');
    await f.writeAsString(
      jsonEncode({
        'id': id,
        'status': status,
        'filePath': filePath,
        'error': error,
        'needsFinalize': needsFinalize,
        'customUri': customUri,
        'sharedSubDir': sharedSubDir,
      }),
    );
  } catch (_) {}
}
