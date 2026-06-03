import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Generates Netflix/CloudStream-style scrub-preview frames by asking the
/// native side ([MediaMetadataRetriever] on Android) to decode the single frame
/// at a timestamp — no second player, no video surface, so it can't hang.
///
/// "Latest target wins": while the user drags, rapid [request] calls collapse
/// to the newest position; only one extraction is ever in flight.
class SeekPreview {
  SeekPreview({required this.uri, this.headers});

  final String uri;
  final Map<String, String>? headers;

  static const MethodChannel _ch = MethodChannel('zangetsu/seek_preview');

  /// The most recent decoded frame (JPEG bytes), or null until the first lands.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  /// Flips to false once an extraction attempt comes back empty (e.g. an HLS
  /// stream the decoder can't grab frames from), so the UI drops the spinner
  /// and shows a plain time bubble instead of spinning forever.
  final ValueNotifier<bool> supported = ValueNotifier<bool>(true);

  bool _disposed = false;
  bool _busy = false;
  bool _firstDone = false;
  Duration? _pending;

  /// Ask for a preview frame at [pos]. Safe to call rapidly while dragging.
  void request(Duration pos) {
    if (_disposed) return;
    _pending = pos;
    _drain();
  }

  Future<void> _drain() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      while (_pending != null && !_disposed) {
        final target = _pending!;
        _pending = null;
        try {
          final bytes = await _ch.invokeMethod<Uint8List>('frame', {
            'url': uri,
            'positionMs': target.inMilliseconds,
            'headers': headers,
            'maxWidth': 320,
          });
          if (_disposed) break;
          if (bytes != null && bytes.isNotEmpty) {
            frame.value = bytes;
            supported.value = true;
          } else if (!_firstDone) {
            supported.value = false;
          }
        } catch (_) {
          if (!_firstDone) supported.value = false;
        } finally {
          _firstDone = true;
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _pending = null;
    try {
      await _ch.invokeMethod('release');
    } catch (_) {}
    // Intentionally do not dispose the notifiers; the owning widget stops
    // listening first, and disposing here risks use-after-dispose on unmount.
  }
}
