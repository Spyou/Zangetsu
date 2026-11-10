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
  static const MethodChannel _method = MethodChannel(
    'com.spyou.watch_app/torrent',
  );
  static const EventChannel _events = EventChannel(
    'com.spyou.watch_app/torrent/events',
  );

  int _generation = 0;
  String? _activeId;
  Future<Map<String, dynamic>?>? _opening;
  Future<void>? _stopping;
  late final Stream<TorrentProgress> _progress = _events
      .receiveBroadcastStream()
      .map((event) => TorrentProgress.fromMap(event as Map));

  /// Starts streaming a magnet/.torrent; returns the torrent id + a local URL
  /// the player can open. Throws on Wi-Fi block (a `wifi_only` PlatformException
  /// when metered + [allowMobileData] is false), no-metadata, or engine error.
  Future<({String id, String localUrl})> startStream(
    String uri, {
    bool allowMobileData = false,
    int? fileIndex,
  }) async {
    final generation = ++_generation;
    await _stopCurrent();
    if (generation != _generation) {
      throw StateError('torrent request cancelled');
    }
    final args = <String, dynamic>{
      'uri': uri,
      'allowMobileData': allowMobileData,
    };
    // Omitted when not requested, so every existing caller keeps the
    // engine's largest-video default.
    if (fileIndex != null) args['fileIndex'] = fileIndex;
    final opening = _method.invokeMapMethod<String, dynamic>(
      'startStream',
      args,
    );
    _opening = opening;
    Map<String, dynamic>? res;
    try {
      res = await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
    if (generation != _generation) {
      throw StateError('torrent request cancelled');
    }
    final id = (res?['id'] ?? '') as String;
    _activeId = id;
    return (id: id, localUrl: (res?['localUrl'] ?? '') as String);
  }

  Stream<TorrentProgress> events() => _progress;

  Future<void> stop(String id) {
    ++_generation;
    return _stopCurrent(id: id);
  }

  Future<void> _stopCurrent({String? id}) {
    final previous = _stopping;
    final opening = _opening;
    final active = _activeId;
    if (previous != null && opening == null && active == null) return previous;
    if (opening == null && active == null && id == null) {
      return Future<void>.value();
    }
    _opening = null;
    _activeId = null;
    final operation = () async {
      if (previous != null) await previous;
      try {
        await _method.invokeMethod<void>('stopStream', {
          'id': id ?? active ?? '',
        });
      } finally {
        // An old native worker must finish cleanup before a new torrent starts.
        if (opening != null) {
          await opening.then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {},
          );
        }
      }
    }();
    late final Future<void> stopping;
    stopping = operation.whenComplete(() {
      if (identical(_stopping, stopping)) _stopping = null;
    });
    _stopping = stopping;
    return stopping;
  }
}
