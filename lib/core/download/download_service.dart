import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:path_provider/path_provider.dart';

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
  static Future<void> initialize() async {
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
  var processing = false;

  Future<void> setNotif(String title, String content) async {
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(title: title, content: content);
    }
  }

  Future<void> process() async {
    if (processing) return;
    processing = true;
    if (service is AndroidServiceInstance) {
      await service.setAsForegroundService();
    }
    while (queue.isNotEmpty) {
      final job = queue.removeAt(0);
      final id = job['id'] as String;
      if (canceled.remove(id)) continue;

      final url = job['url'] as String;
      final headers = Map<String, String>.from(job['headers'] as Map? ?? {});
      final outputPath = job['outputPath'] as String;
      final quality = job['quality'] as String? ?? 'best';
      final label = job['label'] as String? ?? 'Episode';
      final showTitle = job['showTitle'] as String? ?? '';
      final sharedSubDir = job['sharedSubDir'] as String? ?? DownloadService.sharedDir;

      await setNotif('Downloading $showTitle', '$label · 0%');
      service.invoke('progress', {'id': id, 'progress': 0.0});

      var lastPct = -1;
      final ok = await hls.download(
        url: url,
        headers: headers,
        outputPath: outputPath,
        preferredQuality: quality,
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
        continue;
      }
      if (!ok) {
        await _writeResult(id, status: 'failed', error: 'HLS download failed');
        service.invoke('failed', {'id': id, 'error': 'HLS download failed'});
        continue;
      }

      final customUri = job['customUri'] as String?;
      if (customUri != null && customUri.isNotEmpty) {
        // Custom SAF folder: moving into a user-picked tree needs the app's
        // Activity/persisted permission, which this background isolate lacks —
        // hand the local temp + target tree to the main isolate to finish.
        await _writeResult(id, status: 'done', filePath: outputPath);
        service.invoke('done', {
          'id': id,
          'filePath': outputPath,
          'customUri': customUri,
        });
        continue;
      }
      String? finalPath;
      try {
        finalPath = await FileDownloader().moveFileToSharedStorage(
          outputPath,
          SharedStorage.downloads,
          directory: sharedSubDir,
        );
      } catch (_) {}
      finalPath ??= outputPath;
      await _writeResult(id, status: 'done', filePath: finalPath);
      service.invoke('done', {'id': id, 'filePath': finalPath});
    }
    processing = false;
    if (service is AndroidServiceInstance) {
      await service.setAsBackgroundService();
    }
    await service.stopSelf();
  }

  service.on('download').listen((data) {
    if (data == null) return;
    queue.add(data);
    process();
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
}) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docs.path}/${DownloadService.sharedDir}/${DownloadService.resultsDirName}',
    );
    await dir.create(recursive: true);
    final f = File('${dir.path}/$id.json');
    await f.writeAsString(
      jsonEncode({'id': id, 'status': status, 'filePath': filePath, 'error': error}),
    );
  } catch (_) {}
}
