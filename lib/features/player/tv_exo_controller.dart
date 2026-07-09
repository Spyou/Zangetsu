import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side controller for the native ExoPlayer PlatformView (see
/// ExoPlayerView.kt). Wraps the per-view method channel + event stream and
/// exposes playback state as [ValueListenable]s. Engine-only — no source
/// resolution / resume logic (that lives in TvExoPlayerScreen).
class TvExoController {
  TvExoController(int viewId)
      : _method = MethodChannel('zangetsu/exoplayer_$viewId'),
        _events = EventChannel('zangetsu/exoplayer_events_$viewId') {
    _sub = _events.receiveBroadcastStream().listen((e) {
      if (e is Map) applyEvent(Map<String, dynamic>.from(e));
    });
  }

  final MethodChannel _method;
  final EventChannel _events;
  StreamSubscription<dynamic>? _sub;

  final position = ValueNotifier<int>(0); // ms
  final duration = ValueNotifier<int>(0); // ms
  final playing = ValueNotifier<bool>(false);
  final buffering = ValueNotifier<bool>(false);
  final ended = ValueNotifier<bool>(false);

  /// Pure event→state mapping (unit-tested). Tolerates missing/garbage fields.
  void applyEvent(Map<String, dynamic> e) {
    final rawPosition = e['positionMs'];
    final rawDuration = e['durationMs'];
    position.value = rawPosition is num ? rawPosition.toInt() : 0;
    duration.value = rawDuration is num ? rawDuration.toInt() : 0;
    playing.value = e['playing'] == true;
    buffering.value = e['buffering'] == true;
    ended.value = e['ended'] == true;
  }

  /// Whether to fire the one-time resume seek: a real resume point, a known
  /// duration, before the end, and not already done.
  static bool shouldResumeSeek({
    required int resumeMs,
    required int durationMs,
    required bool alreadySeeked,
  }) =>
      !alreadySeeked &&
      resumeMs > 0 &&
      durationMs > 0 &&
      resumeMs < durationMs;

  Future<void> setSource(String url, Map<String, String> headers) =>
      _method.invokeMethod('setSource', {'url': url, 'headers': headers});
  Future<void> play() => _method.invokeMethod('play');
  Future<void> pause() => _method.invokeMethod('pause');
  Future<void> seek(int ms) => _method.invokeMethod('seekTo', {'positionMs': ms});

  void dispose() {
    _sub?.cancel();
    position.dispose();
    duration.dispose();
    playing.dispose();
    buffering.dispose();
    ended.dispose();
  }
}
