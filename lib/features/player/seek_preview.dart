import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Generates Netflix/CloudStream-style scrub-preview frames.
///
/// Two engines, picked per source:
/// * **Local files** (downloads) → native [MediaMetadataRetriever] via the
///   `zangetsu/seek_preview` channel. Instant, free, reliable for files.
/// * **Online streams** (HLS / redirect mirrors) → `keyframe_thumbs`, a
///   standalone native decoder (range-requests + FFmpeg, decodes only the one
///   keyframe needed) via the `zangetsu/keyframe_thumbs` channel. Replaces an
///   earlier hidden-second-mpv-player approach that was flaky (screenshots
///   often came back empty) and re-downloaded the whole stream just to make
///   thumbnails.
///
/// "Latest target wins": rapid [request] calls during a drag collapse to the
/// newest position; only one extraction runs at a time.
class SeekPreview {
  SeekPreview({required this.uri, this.headers, required this.local});

  final String uri;
  final Map<String, String>? headers;

  /// True for on-device files (use MMR); false for http streams (use
  /// keyframe_thumbs).
  final bool local;

  static const MethodChannel _localCh = MethodChannel('zangetsu/seek_preview');
  static const MethodChannel _nativeCh = MethodChannel(
    'zangetsu/keyframe_thumbs',
  );

  /// The most recent decoded frame (JPEG bytes), or null until the first lands.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  bool _disposed = false;
  bool _busy = false;
  Duration? _pending;
  Duration? _latestOnlineTarget;
  static const _intervalMs = 2000;
  static const _cacheLimit = 48;
  final _onlineFrames = <Duration, Uint8List>{};
  final _warmTargets = <Duration>[];
  Timer? _prefetch;

  Duration _samplePosition(Duration pos) =>
      Duration(milliseconds: pos.inMilliseconds ~/ _intervalMs * _intervalMs);

  /// Prepare the current thumbnail and its neighbors without publishing them.
  void warm(
    Duration pos, {
    required Duration duration,
    bool Function()? isBuffering,
  }) {
    if (_disposed || local || duration <= Duration.zero) return;
    _prefetch?.cancel();
    final center = _samplePosition(pos);
    const step = Duration(milliseconds: _intervalMs);
    _warmTargets
      ..clear()
      ..addAll(
        [
          center,
          center + step,
          center - step,
        ].where((target) => target >= Duration.zero && target < duration),
      );
    unawaited(_drain(isBuffering: isBuffering));

    if (isBuffering == null) return;
    final stepMs = math.max(30000, (duration.inMilliseconds / 24).ceil());
    final targets = [
      for (var ms = stepMs ~/ 2; ms < duration.inMilliseconds; ms += stepMs)
        _samplePosition(Duration(milliseconds: ms)),
    ].iterator;
    _prefetch = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_busy || isBuffering()) return;
      if (_warmTargets.isEmpty) {
        if (!targets.moveNext()) {
          timer.cancel();
          return;
        }
        final target = targets.current;
        if (_onlineFrames.containsKey(target)) return;
        _warmTargets.add(target);
      }
      unawaited(_drain(isBuffering: isBuffering));
    });
  }

  /// Ask for a preview frame at [pos]. Safe to call rapidly while dragging.
  void request(Duration pos) {
    if (_disposed) return;
    _prefetch?.cancel();
    _warmTargets.clear();
    final target = local ? pos : _samplePosition(pos);
    if (!local) _latestOnlineTarget = target;
    final cached = _onlineFrames.remove(target);
    if (cached != null) {
      _onlineFrames[target] = cached;
      _pending = null;
      frame.value = cached;
      return;
    }
    if (!local) _showNearest(target);
    _pending = target;
    unawaited(_drain());
  }

  void _showNearest(Duration target) {
    var closestMs = 1 << 53;
    Uint8List? closest;
    for (final entry in _onlineFrames.entries) {
      final distance = (entry.key - target).inMilliseconds.abs();
      if (distance >= closestMs) continue;
      closestMs = distance;
      closest = entry.value;
    }
    frame.value = closest;
  }

  Future<void> _drain({bool Function()? isBuffering}) async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      while (!_disposed && (_pending != null || _warmTargets.isNotEmpty)) {
        final interactive = _pending != null;
        if (!interactive && isBuffering?.call() == true) break;
        final target = _pending ?? _warmTargets.removeAt(0);
        _pending = null;
        if (local) {
          await _localFrame(target);
        } else {
          final bytes = _onlineFrames[target] ?? await _nativeFrame(target);
          if (_disposed || bytes == null || bytes.isEmpty) continue;
          _onlineFrames[target] = bytes;
          if (_onlineFrames.length > _cacheLimit) {
            _onlineFrames.remove(_onlineFrames.keys.first);
          }
          final latest = _latestOnlineTarget;
          if (latest != null && (interactive || _pending == target)) {
            if (_pending == target) _pending = null;
            _showNearest(latest);
          }
        }
      }
    } finally {
      _busy = false;
    }
  }

  // ── Local files: native MediaMetadataRetriever ────────────────────────────
  Future<void> _localFrame(Duration target) async {
    try {
      final bytes = await _localCh.invokeMethod<Uint8List>('frame', {
        'url': uri,
        'positionMs': target.inMilliseconds,
        'headers': headers,
        'maxWidth': 320,
      });
      debugPrint(
        '[seekpreview] local pos=${target.inMilliseconds}ms '
        'bytes=${bytes?.length}',
      );
      if (!_disposed && bytes != null && bytes.isNotEmpty) frame.value = bytes;
    } catch (e) {
      debugPrint('[seekpreview] local ERROR: $e');
    }
  }

  // ── Online streams: keyframe_thumbs (range-request + single-frame decode) ─
  Future<Uint8List?> _nativeFrame(Duration target) async {
    try {
      final bytes = await _nativeCh.invokeMethod<Uint8List>('frame', {
        'url': uri,
        'positionMs': target.inMilliseconds,
        'headers': headers,
      });
      debugPrint(
        '[seekpreview] native pos=${target.inMilliseconds}ms '
        'bytes=${bytes?.length}',
      );
      return bytes;
    } catch (e) {
      debugPrint('[seekpreview] native ERROR: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _prefetch?.cancel();
    _pending = null;
    _warmTargets.clear();
    _onlineFrames.clear();
    try {
      await (local ? _localCh : _nativeCh).invokeMethod('release');
    } catch (_) {}
  }
}
