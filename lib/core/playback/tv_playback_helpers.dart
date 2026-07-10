import 'skip_service.dart';

/// Pure playback decisions for the TV ExoPlayer player. Device-free and
/// unit-tested. shouldScrobble mirrors PlayerCubit._maybeScrobble; unify in SP1d.

/// User-selectable playback rates (UI order).
const List<double> kTvSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// LoudnessEnhancer target gain in millibels for a volume-boost percentage.
/// 100% -> 0 dB, 200% -> +6 dB (~double amplitude, matching mpv volume=2.0).
int volumeBoostToMillibels(int percent) =>
    (((percent.clamp(100, 200) - 100) / 100) * 600).round();

/// Whether to push episode progress now: at/after 92% watched, once.
/// mirrors PlayerCubit._maybeScrobble; unify in SP1d.
bool shouldScrobble({
  required int positionMs,
  required int durationMs,
  required bool alreadyScrobbled,
}) =>
    !alreadyScrobbled && durationMs > 0 && positionMs >= durationMs * 0.92;

/// The OP/ED interval whose [start, end) contains [positionMs], else null.
SkipInterval? activeSkipInterval(List<SkipInterval> intervals, int positionMs) {
  for (final i in intervals) {
    if (positionMs >= i.start.inMilliseconds &&
        positionMs < i.end.inMilliseconds) {
      return i;
    }
  }
  return null;
}
