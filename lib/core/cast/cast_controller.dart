import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/video_source.dart';

// ---------------------------------------------------------------------------
// Cast state
// ---------------------------------------------------------------------------

enum CastState { unavailable, available, connecting, connected }

// ---------------------------------------------------------------------------
// Mime mapping
// ---------------------------------------------------------------------------

/// Maps a [SourceContainer] + URL to the MIME type expected by Chromecast.
///
/// - [hls]     → `application/x-mpegURL`
/// - [mp4]     → `video/mp4`
/// - [unknown] → sniffs by URL extension (`.m3u8` → HLS, otherwise MP4)
String castMimeFor(SourceContainer c, String url) {
  switch (c) {
    case SourceContainer.hls:
      return 'application/x-mpegURL';
    case SourceContainer.mp4:
    case SourceContainer.torrent: // can't cast a torrent stream; treat as mp4
      return 'video/mp4';
    case SourceContainer.unknown:
      // Strip query string before checking extension.
      final path = Uri.tryParse(url)?.path ?? url;
      if (path.contains('.m3u8')) return 'application/x-mpegURL';
      return 'video/mp4';
  }
}

// ---------------------------------------------------------------------------
// CastController
// ---------------------------------------------------------------------------

/// Thin Flutter wrapper around the `zangetsu/cast` native MethodChannel.
///
/// Keeps the cast session state as listenable fields and serialises all
/// channel calls so callers never need to catch [PlatformException].
class CastController extends ChangeNotifier {
  static const _method = MethodChannel('zangetsu/cast');
  static const _events = EventChannel('zangetsu/cast/events');

  // --- Exposed state -------------------------------------------------------

  /// True once [init] confirms the Cast framework is available on this device
  /// (Play Services present). Used to show the cast button even before a device
  /// is found — matches YouTube's always-visible cast icon behaviour.
  bool castSupported = false;

  CastState state = CastState.unavailable;
  String? deviceName;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isPlaying = false;
  /// Non-null when the last `loadMedia` call failed on the receiver side
  /// (e.g. header-locked streams the default receiver can't play).
  /// Cleared to null on the next successful status update or new load.
  String? loadError;

  // --- Private -------------------------------------------------------------

  StreamSubscription<dynamic>? _eventSub;

  // --- Lifecycle -----------------------------------------------------------

  /// Initialises the Chromecast discovery session.
  ///
  /// Must be called once after the app has started. On non-Android platforms
  /// or when the native side is absent the state stays [CastState.unavailable]
  /// and no exception is thrown.
  Future<void> init() async {
    try {
      final supported = await _method.invokeMethod<bool>('init') ?? false;
      castSupported = supported;
      notifyListeners();
      if (supported) {
        _eventSub = _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: (_) {}, // swallow stream errors; state will stay stale
          cancelOnError: false,
        );
      }
    } catch (_) {
      // No native side (iOS / test / missing plugin) — stay unavailable.
    }
  }

  // --- Event parsing -------------------------------------------------------

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final map = Map<String, dynamic>.from(raw);

    final stateStr = map['state'] as String?;
    switch (stateStr) {
      case 'available':
        state = CastState.available;
        break;
      case 'connecting':
        state = CastState.connecting;
        break;
      case 'connected':
        state = CastState.connected;
        break;
      default:
        state = CastState.unavailable;
    }

    deviceName = map['device'] as String?;
    final posMs = (map['positionMs'] as num?)?.toInt() ?? 0;
    final durMs = (map['durationMs'] as num?)?.toInt() ?? 0;
    position = Duration(milliseconds: posMs);
    duration = Duration(milliseconds: durMs);
    isPlaying = (map['playing'] as bool?) ?? false;
    // Optional error field — present only on load failure, absent on success.
    loadError = map.containsKey('error') ? (map['error'] as String?) : null;

    notifyListeners();
  }

  // --- Transport methods ---------------------------------------------------

  /// Loads a media item onto the connected Cast receiver.
  ///
  /// [container] and [url] are passed through [castMimeFor] to derive the
  /// MIME type. [startAt] is sent as `startMs` so the receiver begins
  /// playback at the correct position (resume / manual seek).
  Future<void> loadCurrent({
    required String url,
    required SourceContainer container,
    Map<String, String>? headers,
    String? title,
    String? poster,
    List<Subtitle> subtitles = const [],
    required Duration startAt,
  }) async {
    // Optimistically clear any prior error so the UI doesn't flash stale state.
    if (loadError != null) {
      loadError = null;
      notifyListeners();
    }
    try {
      await _method.invokeMethod<void>('loadMedia', {
        'url': url,
        'mime': castMimeFor(container, url),
        'headers': ?headers,
        'title': ?title,
        'poster': ?poster,
        'subtitles': subtitles
            .map(
              (s) => {
                'url': s.url,
                'lang': s.lang,
                'label': s.label ?? s.lang,
              },
            )
            .toList(),
        'startMs': startAt.inMilliseconds,
      });
    } catch (_) {}
  }

  Future<void> play() async {
    try {
      await _method.invokeMethod<void>('play');
    } catch (_) {}
  }

  Future<void> pause() async {
    try {
      await _method.invokeMethod<void>('pause');
    } catch (_) {}
  }

  Future<void> seek(Duration position) async {
    try {
      await _method.invokeMethod<void>('seek', {'ms': position.inMilliseconds});
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Opens the native Cast device-chooser dialog.
  ///
  /// Once the user selects a device the existing event stream will
  /// automatically transition state to connecting → connected.
  Future<void> pickDevice() async {
    try {
      await _method.invokeMethod<void>('pickDevice');
    } catch (_) {}
  }

  /// Manually request active MediaRouter scanning (belt-and-suspenders; the
  /// native side already starts discovery automatically in [EventChannel.onListen]).
  Future<void> startDiscovery() async {
    if (!castSupported) return;
    try {
      await _method.invokeMethod<void>('startDiscovery');
    } catch (_) {}
  }

  /// Stop active MediaRouter scanning (e.g. when the player is backgrounded).
  Future<void> stopDiscovery() async {
    if (!castSupported) return;
    try {
      await _method.invokeMethod<void>('stopDiscovery');
    } catch (_) {}
  }

  // --- Dispose -------------------------------------------------------------

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
