import 'dart:async';

import '../../core/models/video_source.dart';
import '../../core/playback/source_selection.dart';

/// Whether a Z-mode episode should be resolved through its progressive sweep.
/// A preferred local source, when available, should be opened first instead.
bool shouldUseProgressivePlayback({
  required bool progressiveAvailable,
  required bool hasLocalSource,
}) => progressiveAvailable && !hasLocalSource;

/// Retry only a failed local codec open, once, when the user has not already
/// chosen software decoding. Network playback and other local errors are left
/// to their existing recovery paths.
bool shouldRetryWithSoftwareDecoder({
  required bool isLocalFile,
  required bool alreadyRetried,
  required bool softwareDecoderSelected,
  required String error,
}) =>
    isLocalFile &&
    !alreadyRetried &&
    !softwareDecoderSelected &&
    error.toLowerCase().contains('codec');

bool isCurrentSoftwareDecoderRetry({
  required int retryGeneration,
  required int currentGeneration,
}) =>
    retryGeneration == currentGeneration;

bool shouldInvalidateSoftwareDecoderRetry({
  required bool retryInProgress,
  required bool openingRetry,
}) =>
    retryInProgress && !openingRetry;

/// Return a one-open `hwdec` override for a local software fallback, or null
/// when the player's normal decoder preference should remain untouched.
String? softwareDecoderOverride({
  required bool retryWithSoftware,
  required bool fallbackActive,
  required String preferredHwdec,
}) {
  if (retryWithSoftware) return 'no';
  if (fallbackActive) return preferredHwdec;
  return null;
}

/// Polls a provider's existing resolution session briefly for late mirrors.
/// Links already returned are retained and duplicate URLs are ignored.
Future<List<VideoSource>> collectLatePlaybackMirrors({
  required List<VideoSource> initial,
  required Future<({List<VideoSource> sources, bool done})> Function() poll,
  bool Function()? isStillCurrent,
  Duration maxWait = const Duration(seconds: 3),
  Duration pollInterval = const Duration(milliseconds: 300),
}) async {
  final sources = List<VideoSource>.of(initial);
  final seen = initial.map((source) => source.url).toSet();
  if (maxWait <= Duration.zero) return sources;

  final timer = Stopwatch()..start();
  while (timer.elapsed < maxWait) {
    if (isStillCurrent != null && !isStillCurrent()) return sources;
    final remaining = maxWait - timer.elapsed;
    ({List<VideoSource> sources, bool done}) result;
    try {
      result = await poll().timeout(remaining);
    } on TimeoutException {
      continue;
    } catch (_) {
      return sources;
    }

    for (final source in result.sources) {
      if (seen.add(source.url)) sources.add(source);
    }
    if (result.done) return sources;

    final pause = maxWait - timer.elapsed;
    if (pause > Duration.zero && pollInterval > Duration.zero) {
      await Future<void>.delayed(pollInterval < pause ? pollInterval : pause);
    }
  }
  return sources;
}

/// Selects an untried mirror without switching a known audio cut.
///
/// Unknown-cut links remain eligible when a provider doesn't label its audio;
/// a known opposite cut is never chosen as an automatic startup fallback.
VideoSource? pickPlaybackFallback({
  required VideoSource failed,
  required List<VideoSource> sources,
  required Set<String> triedUrls,
  required String preferredQuality,
}) {
  final untried = sources
      .where((source) => !triedUrls.contains(source.url))
      .toList();
  if (untried.isEmpty) return null;

  final eligible = failed.kind == AudioKind.unknown
      ? untried
      : untried
            .where(
              (source) =>
                  source.kind == failed.kind ||
                  source.kind == AudioKind.unknown,
            )
            .toList();
  return pickDefault(
    eligible,
    prefer: failed.kind,
    preferQuality: preferredQuality,
  );
}
