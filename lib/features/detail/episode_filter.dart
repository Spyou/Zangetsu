import '../../core/models/episode.dart';

/// CloudStream-style chunk size for long season navigation (1–50, 51–100, …).
const kEpisodeRangeChunk = 50;

/// Filters [episodes] by a case-insensitive substring [query] over each
/// episode's title and number. An empty/whitespace query returns the list
/// unchanged. A whole-number match ignores the trailing `.0` (so "12" matches
/// episode `12.0`, and "1.5" matches `1.5`).
List<Episode> filterEpisodes(List<Episode> episodes, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return episodes;
  return episodes.where((e) {
    if (e.title.toLowerCase().contains(q)) return true;
    final n = e.number;
    if (n != null) {
      final s = n == n.roundToDouble() ? n.toInt().toString() : n.toString();
      if (s.contains(q)) return true;
    }
    return false;
  }).toList();
}

/// How many range chips a list of [total] episodes needs.
int episodeRangeCount(int total) => (total / kEpisodeRangeChunk).ceil();

/// Which range chip holds [localIndex] in the filtered list (-1 → 0).
int episodeRangeIndex(int localIndex) =>
    localIndex < 0 ? 0 : localIndex ~/ kEpisodeRangeChunk;

/// Inclusive [start], exclusive [end] slice bounds for [rangeIndex].
({int start, int end}) episodeRangeSlice(int rangeIndex, int total) {
  final start = (rangeIndex * kEpisodeRangeChunk).clamp(0, total);
  final end = (start + kEpisodeRangeChunk).clamp(0, total);
  return (start: start, end: end);
}

/// Display label for a range chip, e.g. `1–50` or `51–60`.
String episodeNumLabel(Episode e, int fallback) =>
    (e.number?.toInt() ?? fallback).toString();

String episodeRangeLabel(List<Episode> episodes, int rangeIndex) {
  final total = episodes.length;
  if (total == 0) return '';
  final s = (rangeIndex * kEpisodeRangeChunk).clamp(0, total - 1);
  final e = ((rangeIndex + 1) * kEpisodeRangeChunk - 1).clamp(0, total - 1);
  return '${episodeNumLabel(episodes[s], s + 1)}'
      '–${episodeNumLabel(episodes[e], e + 1)}';
}
