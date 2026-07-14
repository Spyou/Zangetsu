// lib/features/player/engine/playback_engine.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A resolved, playable source handed to an engine. Mirrors the fields the
/// current controller already resolves before opening mpv.
class EngineSource {
  const EngineSource({
    required this.url,
    this.headers = const {},
    this.mimeType,
    this.isHls = false,
    this.isTorrent = false,
    this.hasAssSubtitles = false,
  });

  final String url;
  final Map<String, String> headers;

  /// Container hint (e.g. 'application/x-mpegURL', 'video/mp4'); null → infer.
  final String? mimeType;

  /// HLS (.m3u8) source — needs mpv's per-segment reconnect demuxer opts.
  final bool isHls;

  /// Magnet/.torrent (or a local file served by the torrent HTTP bridge).
  final bool isTorrent;

  /// Source advertises styled ASS/SSA subtitles (mpv renders these richer).
  final bool hasAssSubtitles;
}

/// One selectable audio/text track, engine-agnostic.
class EngineTrack {
  const EngineTrack({
    required this.id,
    this.language = '',
    this.label,
    this.selected = false,
  });
  final String id;
  final String language;
  final String? label;
  final bool selected;
}

/// A fatal engine error used to decide fallback. [framesRendered] distinguishes
/// "never started" (safe to fall back) from "died mid-playback".
class EngineError {
  const EngineError({required this.code, required this.framesRendered});
  final String code;
  final bool framesRendered;
}

/// Engine-agnostic subtitle styling (superset used by both overlay + native).
class EngineSubtitleStyle {
  const EngineSubtitleStyle({
    this.scale = 1.0,
    this.fontPath,
    this.fgColor,
    this.bgColor,
    this.edge = 0,
    this.position = 0,
  });
  final double scale;
  final String? fontPath;
  final int? fgColor; // ARGB
  final int? bgColor; // ARGB
  final int edge;
  final int position;
}

/// Playback engine contract. Reactive state is exposed as [ValueListenable]s;
/// commands return [Future]s. The owning controller talks ONLY to this.
abstract class PlaybackEngine {
  // ── reactive state (read) ──
  ValueListenable<Duration> get position;
  ValueListenable<Duration> get duration;
  ValueListenable<bool> get playing;
  ValueListenable<bool> get buffering;
  ValueListenable<bool> get completed;
  ValueListenable<double> get rate;
  ValueListenable<int> get videoWidth; // 0 until known; screen uses for aspect
  ValueListenable<List<EngineTrack>> get audioTracks;
  ValueListenable<List<EngineTrack>> get textTracks;

  /// Fatal errors (decoder init fail, unsupported codec). Drives fallback.
  Stream<EngineError> get errors;

  // Stream forms of the reactive state, for existing StreamBuilder call sites.
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<bool> get completedStream;
  /// Video width in px (0 until known).
  Stream<int> get widthStream;
  /// Buffered-ahead position (for the seek bar's buffered indicator).
  Stream<Duration> get bufferedStream;

  // ── commands ──
  Future<void> load(EngineSource source, {Duration startAt = Duration.zero});
  Future<void> play();
  Future<void> pause();

  /// Atomically toggle play/pause based on the engine's OWN current state (not a
  /// Dart-side cached flag, which can lag). Mirrors mpv's `playOrPause`.
  Future<void> playOrPause();

  Future<void> seek(Duration to);
  Future<void> setRate(double rate);

  /// 0.0–1.0 base volume.
  Future<void> setVolume(double volume);

  /// Extra gain above 100% (e.g. 100 = +100%); 0 = none.
  Future<void> setVolumeBoost(int percent);

  Future<void> selectAudioTrack(String id);

  /// null id → subtitles off.
  Future<void> selectTextTrack(String? id);

  Future<void> addExternalSubtitle(String uriOrPath,
      {String? language, bool select = true});

  Future<void> setSubtitleStyle(EngineSubtitleStyle style);

  /// Subtitle timing offset (positive = subtitles later). mpv: `sub-delay`.
  /// Engines without native support may no-op.
  Future<void> setSubtitleDelay(Duration delay);

  /// Audio timing offset (positive = audio later). mpv: `audio-delay`.
  /// Engines without native support may no-op.
  Future<void> setAudioDelay(Duration delay);

  /// Cap the adaptive/HLS variant by bandwidth in bits/s. `<= 0` = auto/max.
  Future<void> setMaxVideoBitrate(int bandwidth);

  /// The video render surface for this engine (mpv Video widget or the
  /// ExoPlayer PlatformView). Owns subtitle rendering appropriate to the engine.
  /// [fit] drives the Fit/Fill/Stretch toggle; engines never draw their own
  /// controls (the app renders its own player UI).
  Widget buildVideo(BuildContext context, {BoxFit fit = BoxFit.contain});

  Future<void> dispose();
}
