// lib/features/player/engine/engine_router.dart
import 'playback_engine.dart';

enum EngineChoice { mpv, exo }

/// Decides which engine plays a given source. Pure + unit-tested so the policy
/// is easy to reason about and tighten. The toggle-off case is the primary
/// "don't break anything" lever: it always returns mpv (today's behaviour).
class EngineRouter {
  /// Pick the engine for [source].
  ///  • Toggle off → always mpv.
  ///  • Torrents → mpv (the local HTTP bridge + libtorrent pipeline is tuned
  ///    for mpv; ExoPlayer has no equivalent).
  ///  • ASS/SSA-subtitle sources → mpv (libass renders styled subs richer than
  ///    ExoPlayer's cue renderer).
  ///  • Otherwise → exo (the fast native path).
  static EngineChoice pick({
    required EngineSource source,
    required bool fastPlayer,
  }) {
    if (!fastPlayer) return EngineChoice.mpv;
    if (source.isTorrent) return EngineChoice.mpv;
    if (source.hasAssSubtitles) return EngineChoice.mpv;
    return EngineChoice.exo;
  }
}

/// Whether an ExoPlayer fatal error should drop playback back to mpv. Any fatal
/// engine error is worth a fallback — ExoPlayer only errors fatally on things
/// mpv can usually still play (exotic codecs, DTS audio, odd containers). Kept
/// as a function so the policy is unit-tested and easy to tighten later.
bool shouldFallback(EngineError e) => true;
