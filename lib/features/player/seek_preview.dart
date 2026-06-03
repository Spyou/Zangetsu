import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Generates Netflix-style scrub-preview frames on demand by driving a second,
/// hidden, muted player. We have no pre-baked sprite sheets (providers don't
/// supply them), so frames are produced live: instant for local/offline files,
/// best-effort for online streams.
///
/// "Latest target wins" — while the user drags, rapid [request] calls collapse
/// to the newest position; intermediate ones are dropped so we never queue up a
/// backlog of stale seeks.
class SeekPreview {
  SeekPreview({required this.uri, this.headers});

  final String uri;
  final Map<String, String>? headers;

  /// The most recent decoded frame (JPEG bytes), or null until the first one
  /// lands. Widgets listen to this to paint the preview.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  Player? _player;
  // Kept alive so mpv has a video output to screenshot from; never displayed.
  // ignore: unused_field
  VideoController? _video;
  bool _opening = false;
  bool _disposed = false;
  bool _busy = false;
  Duration? _pending;

  Future<void> _ensureOpen() async {
    if (_player != null || _opening || _disposed) return;
    _opening = true;
    final p = Player();
    // A VideoController gives mpv a render target; screenshot-raw reads from it.
    _video = VideoController(p);
    _player = p;
    await p.setVolume(0);
    final plat = p.platform;
    if (plat is NativePlayer) {
      try {
        // Hardware decoding can make screenshot-raw return empty frames, and we
        // only need the occasional keyframe — force software decoding.
        await plat.setProperty('hwdec', 'no');
        await plat.setProperty('force-seekable', 'yes');
      } catch (_) {}
    }
    await p.open(Media(uri, httpHeaders: headers), play: false);
    _opening = false;
    if (_disposed) {
      await p.dispose();
      _player = null;
      _video = null;
    }
  }

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
      await _ensureOpen();
      while (_pending != null && !_disposed) {
        final target = _pending!;
        _pending = null;
        final p = _player;
        if (p == null) break;
        try {
          await p.seek(target);
          // Let mpv land the keyframe before grabbing it.
          await Future<void>.delayed(const Duration(milliseconds: 110));
          final bytes = await p.screenshot(format: 'image/jpeg');
          if (_disposed) break;
          if (bytes != null && bytes.isNotEmpty) frame.value = bytes;
        } catch (_) {
          // Best-effort: keep the last good frame on screen and try the next.
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _pending = null;
    final p = _player;
    _player = null;
    _video = null;
    await p?.dispose();
    // Intentionally do not dispose `frame`; the owning widget stops listening
    // first, and disposing here would risk a use-after-dispose during unmount.
  }
}
