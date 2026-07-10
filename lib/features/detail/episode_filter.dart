import '../../core/models/episode.dart';

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
