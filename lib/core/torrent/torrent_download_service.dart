import 'package:flutter/services.dart';

/// One progress event for a torrent DOWNLOAD (offline save), distinct from the
/// streaming engine. `status` in: queued | downloading | copying | done |
/// failed | paused.
class TorrentDownloadProgress {
  const TorrentDownloadProgress({
    required this.id,
    required this.status,
    required this.progress,
    required this.peers,
    required this.downSpeedBps,
    this.filePath,
    this.error,
  });

  final String id;
  final String status;
  final double progress; // 0..1
  final int peers;
  final int downSpeedBps;
  final String? filePath; // final path/content:// once done
  final String? error;

  static TorrentDownloadProgress fromMap(Map<dynamic, dynamic> m) =>
      TorrentDownloadProgress(
        id: (m['id'] ?? '') as String,
        status: (m['status'] ?? 'queued') as String,
        progress: ((m['progress'] ?? 0) as num).toDouble(),
        peers: ((m['peers'] ?? 0) as num).toInt(),
        downSpeedBps: ((m['downSpeedBps'] ?? 0) as num).toInt(),
        filePath: m['filePath'] as String?,
        error: m['error'] as String?,
      );
}

/// Dart client for the native torrent DOWNLOAD engine (offline save). Separate
/// from [TorrentService] (streaming) — different channels, different engine.
class TorrentDownloadService {
  static const MethodChannel _method =
      MethodChannel('com.spyou.watch_app/torrent_download');
  static const EventChannel _events =
      EventChannel('com.spyou.watch_app/torrent_download/events');

  /// Start (or queue) an offline download of [uri] (magnet/.torrent) under [id].
  /// [saveTreeUri] is the user's chosen SAF folder (null = app storage). Throws
  /// a `wifi_only` PlatformException when metered + [allowMobileData] is false.
  Future<void> enqueue(
    String id,
    String uri, {
    String? saveTreeUri,
    required bool allowMobileData,
  }) =>
      _method.invokeMethod('enqueue', {
        'id': id,
        'uri': uri,
        'saveTreeUri': saveTreeUri,
        'allowMobileData': allowMobileData,
      });

  Future<void> pause(String id) => _method.invokeMethod('pause', {'id': id});
  Future<void> resume(String id) => _method.invokeMethod('resume', {'id': id});
  Future<void> cancel(String id) => _method.invokeMethod('cancel', {'id': id});

  Stream<TorrentDownloadProgress> events() => _events
      .receiveBroadcastStream()
      .map((x) => TorrentDownloadProgress.fromMap(x as Map));
}
