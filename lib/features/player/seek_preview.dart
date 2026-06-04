import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Generates Netflix/CloudStream-style scrub-preview frames.
///
/// Two engines, picked per source:
/// * **Local files** (downloads) → native [MediaMetadataRetriever] via the
///   `zangetsu/seek_preview` channel. Instant, free, reliable for files.
/// * **Online streams** (HLS / redirect mirrors) → a hidden, muted second mpv
///   player. MediaMetadataRetriever can't decode those (its HTTP layer throws
///   on byte-range reads), but mpv plays them natively. mpv only renders frames
///   we can screenshot when its texture is actually painted, so the UI must
///   mount a tiny [Video] using [videoController] while previewing.
///
/// "Latest target wins": rapid [request] calls during a drag collapse to the
/// newest position; only one extraction runs at a time.
class SeekPreview {
  SeekPreview({required this.uri, this.headers, required this.local});

  final String uri;
  final Map<String, String>? headers;

  /// True for on-device files (use MMR); false for http streams (use mpv).
  final bool local;

  static const MethodChannel _ch = MethodChannel('zangetsu/seek_preview');

  /// The most recent decoded frame (JPEG bytes), or null until the first lands.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  /// For the mpv (online) engine: set once the hidden player is open so the UI
  /// can mount an off-screen [Video] (required for mpv to render frames).
  final ValueNotifier<VideoController?> videoController =
      ValueNotifier<VideoController?>(null);

  /// Whether this preview needs a mounted [Video] (online/mpv mode only).
  bool get usesVideo => !local;

  Player? _player;
  bool _opening = false;
  bool _disposed = false;
  bool _busy = false;
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
        if (local) {
          await _localFrame(target);
        } else {
          await _mpvFrame(target);
        }
      }
    } finally {
      _busy = false;
    }
  }

  // ── Local files: native MediaMetadataRetriever ────────────────────────────
  Future<void> _localFrame(Duration target) async {
    try {
      final bytes = await _ch.invokeMethod<Uint8List>('frame', {
        'url': uri,
        'positionMs': target.inMilliseconds,
        'headers': headers,
        'maxWidth': 320,
      });
      debugPrint('[seekpreview] local pos=${target.inMilliseconds}ms '
          'bytes=${bytes?.length}');
      if (!_disposed && bytes != null && bytes.isNotEmpty) frame.value = bytes;
    } catch (e) {
      debugPrint('[seekpreview] local ERROR: $e');
    }
  }

  // ── Online streams: hidden mpv player ─────────────────────────────────────
  Future<void> _ensureMpv() async {
    if (_player != null || _opening || _disposed) return;
    _opening = true;
    final p = Player();
    // A VideoController gives mpv a render target; the UI mounts a tiny Video
    // for it so frames actually render (screenshot reads the decoded frame).
    final vc = VideoController(p);
    _player = p;
    await p.setVolume(0);
    final plat = p.platform;
    if (plat is NativePlayer) {
      try {
        // No audio output at all — otherwise this hidden player grabs Android
        // audio focus when nudged and PAUSES the main player. It also never
        // needs sound. Disable the audio track + output device entirely.
        await plat.setProperty('ao', 'null');
        await plat.setProperty('aid', 'no');
        // Software frames are screenshot-able (hw buffers often aren't); grab
        // the lowest HLS variant to keep data + decode cost down.
        await plat.setProperty('hwdec', 'no');
        await plat.setProperty('force-seekable', 'yes');
        await plat.setProperty('hls-bitrate', 'min');
      } catch (_) {}
    }
    await p.open(Media(uri, httpHeaders: headers), play: false);
    if (!_disposed) videoController.value = vc;
    _opening = false;
    debugPrint('[seekpreview] mpv opened uri=$uri');
    if (_disposed) {
      await p.dispose();
      _player = null;
    }
  }

  Future<void> _mpvFrame(Duration target) async {
    try {
      await _ensureMpv();
      final p = _player;
      if (p == null || _disposed) return;
      await p.seek(target);
      // A paused player may not render a screenshot-able frame; nudge playback
      // so mpv decodes/renders the frame at the seek point, then pause again.
      await p.play();
      debugPrint('[seekpreview] mpv seek=${target.inMilliseconds}ms');
      // Poll for a frame: a streamed seek needs time to land + decode. Bail
      // early if a newer scrub position arrives (latest-target-wins).
      for (var i = 0; i < 10 && !_disposed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 140));
        if (_pending != null) {
          await p.pause();
          return;
        }
        final bytes = await p.screenshot(format: 'image/jpeg');
        if (_disposed) return;
        debugPrint('[seekpreview] mpv shot#$i bytes=${bytes?.length}');
        if (bytes != null && bytes.isNotEmpty) {
          frame.value = bytes;
          await p.pause();
          return;
        }
      }
      await p.pause();
    } catch (e) {
      debugPrint('[seekpreview] mpv ERROR: $e');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _pending = null;
    try {
      await _ch.invokeMethod('release');
    } catch (_) {}
    final p = _player;
    _player = null;
    await p?.dispose();
    // Notifiers are intentionally not disposed; the owning widget stops
    // listening first, and disposing here risks use-after-dispose on unmount.
  }
}
