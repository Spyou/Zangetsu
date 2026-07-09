import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/playback/tv_track_helpers.dart';

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
  final audioTracks = ValueNotifier<List<TvTrack>>(const []);
  final textTracks = ValueNotifier<List<TvTrack>>(const []);

  /// Pure event→state mapping (unit-tested). Tolerates missing/garbage fields.
  void applyEvent(Map<String, dynamic> e) {
    final rawPosition = e['positionMs'];
    final rawDuration = e['durationMs'];
    position.value = rawPosition is num ? rawPosition.toInt() : 0;
    duration.value = rawDuration is num ? rawDuration.toInt() : 0;
    playing.value = e['playing'] == true;
    buffering.value = e['buffering'] == true;
    ended.value = e['ended'] == true;
    if (e.containsKey('audioTracks')) {
      final a = _parseTracks(e['audioTracks']);
      if (!_tracksEqual(audioTracks.value, a)) audioTracks.value = a;
    }
    if (e.containsKey('textTracks')) {
      final t = _parseTracks(e['textTracks']);
      if (!_tracksEqual(textTracks.value, t)) textTracks.value = t;
    }
  }

  static List<TvTrack> _parseTracks(dynamic raw) {
    if (raw is! List) return const [];
    final out = <TvTrack>[];
    for (final item in raw) {
      if (item is Map) {
        final label = '${item['label'] ?? ''}';
        out.add(TvTrack(
          id: '${item['id'] ?? ''}',
          language: '${item['language'] ?? ''}',
          label: label.isEmpty ? null : label,
          selected: item['selected'] == true,
        ));
      }
    }
    return out;
  }

  static bool _tracksEqual(List<TvTrack> a, List<TvTrack> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].selected != b[i].selected) return false;
    }
    return true;
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

  Future<void> setSource(
    String url,
    Map<String, String> headers, {
    List<TvSubtitleConfig> subtitles = const [],
  }) =>
      _method.invokeMethod('setSource', {
        'url': url,
        'headers': headers,
        'subtitles': subtitles.map((s) => s.toMap()).toList(),
      });
  Future<void> play() => _method.invokeMethod('play');
  Future<void> pause() => _method.invokeMethod('pause');
  Future<void> seek(int ms) => _method.invokeMethod('seekTo', {'positionMs': ms});

  Future<void> selectAudioTrack(String id) =>
      _method.invokeMethod('selectAudioTrack', {'id': id});
  Future<void> selectTextTrack(String? id) =>
      _method.invokeMethod('selectTextTrack', {'id': id});
  Future<void> setMaxVideoBitrate(int bandwidth) =>
      _method.invokeMethod('setMaxVideoBitrate', {'bandwidth': bandwidth});
  Future<void> applyCaptionStyle(TvCaptionStyle s, {String? fontPath}) =>
      _method.invokeMethod('setCaptionStyle', {
        'scale': s.scale,
        'fontPath': fontPath,
        'fgColor': s.fgColor,
        'bgColor': s.bgColor,
        'edge': s.edge,
        'position': s.position,
      });
  Future<void> setPlaybackSpeed(double speed) =>
      _method.invokeMethod('setPlaybackSpeed', {'speed': speed});
  Future<void> setVolumeBoost(int percent) =>
      _method.invokeMethod('setVolumeBoost', {'percent': percent});

  void dispose() {
    _sub?.cancel();
    position.dispose();
    duration.dispose();
    playing.dispose();
    buffering.dispose();
    ended.dispose();
    audioTracks.dispose();
    textTracks.dispose();
  }
}
