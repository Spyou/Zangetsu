import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../models/video_source.dart';

// ---------------------------------------------------------------------------
// Cast state
// ---------------------------------------------------------------------------

enum CastState { unavailable, available, connecting, connected }

/// CAF [MediaStatus.playerState] names for shared logs.
String castPlayerStateName(int state) => switch (state) {
  1 => 'idle',
  2 => 'playing',
  3 => 'paused',
  4 => 'buffering',
  5 => 'loading',
  _ => 'unknown($state)',
};

/// CAF [MediaStatus.idleReason] names for shared logs.
String castIdleReasonName(int reason) => switch (reason) {
  0 => 'none',
  1 => 'finished',
  2 => 'canceled',
  3 => 'interrupted',
  4 => 'error',
  _ => 'unknown($reason)',
};

// ---------------------------------------------------------------------------
// Mime mapping
// ---------------------------------------------------------------------------

/// Maps a [Subtitle] to the payload [CastController.loadCurrent] sends
/// natively. Chromecast's Default Media Receiver only accepts WebVTT; SRT is
/// advertised as `vtt` because the LAN proxy converts it on the way out.
List<Map<String, String>> castSubtitleMaps(List<Subtitle> subtitles) {
  return [
    for (final s in subtitles)
      if (canCastSubtitle(s))
        {
          'url': s.url,
          'lang': s.lang,
          'label': s.label ?? s.lang,
          'format': 'vtt',
        },
  ];
}

/// Soft-subs the Default Media Receiver can actually load. ASS/SSA are
/// rejected (Invalid Request / 2001); SRT is converted to VTT in the proxy.
bool canCastSubtitle(Subtitle s) {
  final format = (s.format ?? '').toLowerCase();
  final path = (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase();
  if (format == 'ass' || format == 'ssa') return false;
  if (path.endsWith('.ass') || path.endsWith('.ssa')) return false;
  return true;
}

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

  /// CAF [MediaStatus.playerState] / [idleReason]. Logged on change so a
  /// shared `zangetsu.log` can show play/pause/idle without native logcat.
  int playerState = 0;
  int idleReason = 0;

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

    final prevState = state;
    final prevPlayer = playerState;
    final prevIdle = idleReason;
    final prevError = loadError;

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
    playerState = (map['playerState'] as num?)?.toInt() ?? 0;
    idleReason = (map['idleReason'] as num?)?.toInt() ?? 0;
    // Optional error field — present only on load failure, absent on success.
    loadError = map.containsKey('error') ? (map['error'] as String?) : null;

    if (state != prevState ||
        playerState != prevPlayer ||
        idleReason != prevIdle ||
        loadError != prevError) {
      AppLogger.instance.log(
        '[cast] ${state.name} player=${castPlayerStateName(playerState)} '
        'idle=${castIdleReasonName(idleReason)}'
        '${deviceName != null ? ' · $deviceName' : ''}'
        '${loadError != null ? ' · error=$loadError' : ''}',
      );
    }

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
    String? mime,
    String? title,
    String? poster,
    List<Subtitle> subtitles = const [],
    required Duration startAt,
    Duration duration = Duration.zero,
    String? hlsSegmentFormat,
    String? hlsVideoSegmentFormat,
  }) async {
    // Optimistically clear any prior error so the UI doesn't flash stale state.
    if (loadError != null) {
      loadError = null;
      notifyListeners();
    }
    try {
      await _method.invokeMethod<void>('loadMedia', {
        'url': url,
        // Prefer an explicit mime (the proxy URL has no extension to sniff);
        // otherwise derive it from the container / URL.
        'mime': mime ?? castMimeFor(container, url),
        'headers': ?headers,
        'title': ?title,
        'poster': ?poster,
        'subtitles': castSubtitleMaps(subtitles),
        'startMs': startAt.inMilliseconds,
        if (duration > Duration.zero) 'durationMs': duration.inMilliseconds,
        if (hlsSegmentFormat != null) 'hlsSegmentFormat': hlsSegmentFormat,
        if (hlsVideoSegmentFormat != null)
          'hlsVideoSegmentFormat': hlsVideoSegmentFormat,
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
