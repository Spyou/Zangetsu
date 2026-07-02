import 'package:flutter/services.dart';

enum TorrentState { finding, buffering, ready, error }

class TorrentProgress {
  const TorrentProgress({
    required this.id,
    required this.state,
    required this.bufferPct,
    required this.peers,
    required this.downSpeedBps,
    this.error,
  });
  final String id;
  final TorrentState state;
  final double bufferPct;
  final int peers;
  final int downSpeedBps;
  final String? error;

  static TorrentProgress fromMap(Map<dynamic, dynamic> m) => TorrentProgress(
        id: (m['id'] ?? '') as String,
        state: _stateFrom(m['state'] as String?),
        bufferPct: ((m['bufferPct'] ?? 0) as num).toDouble(),
        peers: ((m['peers'] ?? 0) as num).toInt(),
        downSpeedBps: ((m['downSpeedBps'] ?? 0) as num).toInt(),
        error: m['error'] as String?,
      );

  static TorrentState _stateFrom(String? s) => switch (s) {
        'finding' => TorrentState.finding,
        'buffering' => TorrentState.buffering,
        'ready' => TorrentState.ready,
        'error' => TorrentState.error,
        _ => TorrentState.finding,
      };
}

class TorrentService {
  static const MethodChannel _method =
      MethodChannel('com.spyou.watch_app/torrent');
  static const EventChannel _events =
      EventChannel('com.spyou.watch_app/torrent/events');

  /// Starts streaming a magnet/.torrent; returns the torrent id + a local URL
  /// the player can open. Throws on Wi-Fi block / no-metadata / engine error.
  Future<({String id, String localUrl})> startStream(String uri) async {
    final res = await _method.invokeMapMethod<String, dynamic>(
      'startStream',
      {'uri': uri},
    );
    return (
      id: (res?['id'] ?? '') as String,
      localUrl: (res?['localUrl'] ?? '') as String,
    );
  }

  Stream<TorrentProgress> events() => _events
      .receiveBroadcastStream()
      .map((e) => TorrentProgress.fromMap(e as Map));

  Future<void> stop(String id) =>
      _method.invokeMethod('stopStream', {'id': id});
}
