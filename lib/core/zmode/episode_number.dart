/// Working out which of a source's episodes a canonical episode number means.
///
/// The metadata side numbers episodes 1..N by position (see
/// `MetadataRepository._canonicalize`). Asking the source for "number 5" by
/// taking its 5th entry is right until the source slips something extra into
/// the list — a recap, a special, a season-0 entry — and then every episode
/// after it is off by one. Both the video AND the tracker progress are wrong,
/// because progress is keyed on that number.
///
/// Every comparable app resolves this by the episode's own number rather than
/// its position. The catch is that source numbering is not always trustworthy:
/// some list a season's episodes as 1..12 when the metadata entry covers the
/// whole run. So this only uses numbers when they look reliable, and otherwise
/// falls back to position — which is what the app has always done.
library;

import '../models/episode.dart';

/// The number a source is reporting for [e], or null when it isn't saying.
///
/// Prefers the field: CloudStream extensions report a real episode number, and
/// a stated number always beats one guessed from a title. Aniyomi-style sources
/// usually only give a title, so that gets parsed.
double? sourceEpisodeNumber(Episode e) {
  final n = e.number;
  if (n != null && n > 0) return n;
  return parseEpisodeNumber(e.title);
}

/// The episode number written in a source's episode title, or null.
///
/// Titles arrive in every shape sources can invent:
///
///     "Episode 5"                    -> 5
///     "Ep. 5 [1080p]"                -> 5
///     "Bleach - 5 (v2)"              -> 5
///     "Episode 5.5 - Recap"          -> 5.5
///     "S2 - Episode 3"               -> 3
///
/// Resolutions, version tags and season markers are stripped first — they are
/// numbers too, and "1080p" reading as episode 1080 is worse than no answer.
double? parseEpisodeNumber(String raw) {
  var s = raw.toLowerCase();
  // Bracketed tags are release-group noise: [1080p], (BD), [Multi-Sub].
  s = s.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), ' ');
  // Numbers that are not episode numbers, in the order they mislead:
  // resolutions, version marks, season markers, bit-depth.
  s = s.replaceAll(
    RegExp(r'\b\d+\s*p\b|\bv\d+\b|\b(?:season|s)\s*\d+\b|\bhi10p?\b'),
    ' ',
  );
  // An explicit marker is the strongest signal there is.
  final marked = RegExp(
    r'(?:\bepisode|\bep|\be)\s*\.?\s*(\d+(?:\.\d+)?)',
  ).firstMatch(s);
  if (marked != null) return double.tryParse(marked.group(1)!);
  // Otherwise the first number left standing, once the noise is gone.
  final bare = RegExp(r'(?<![\d.])(\d+(?:\.\d+)?)(?![\d.])').firstMatch(s);
  return bare == null ? null : double.tryParse(bare.group(1)!);
}

/// Whether [numbers] can be trusted to identify episodes.
///
/// Trustworthy means: every episode stated a number, and those numbers only go
/// up. A repeat or a step backwards is how per-season restarts and unnumbered
/// filler show up, and either makes "the episode numbered 5" ambiguous — at
/// which point position is the safer answer.
bool episodeNumbersAreReliable(List<double?> numbers) {
  if (numbers.length < 2) return false;
  double? previous;
  for (final n in numbers) {
    if (n == null || n <= 0) return false;
    if (previous != null && n <= previous) return false;
    previous = n;
  }
  return true;
}

/// Which entry of [eps] the canonical [wanted] number refers to, or -1.
///
/// Falls back to `wanted - 1` — the position the app has always used — when
/// the source's numbering isn't reliable or doesn't contain [wanted]. So this
/// can correct a mismatch but never invent one: where it can't improve on
/// position, it returns position.
int resolveEpisodeIndex(List<Episode> eps, int wanted) {
  final numbers = [for (final e in eps) sourceEpisodeNumber(e)];
  if (episodeNumbersAreReliable(numbers)) {
    final i = numbers.indexOf(wanted.toDouble());
    if (i >= 0) return i;
  }
  return wanted - 1;
}
