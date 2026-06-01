import '../models/video_source.dart';

/// Parses a quality label like `'1080p'` into a comparable int (height in px).
/// Unknown/empty → -1 so it sorts last.
int qualityRank(String? quality) {
  if (quality == null) return -1;
  final m = RegExp(r'(\d{3,4})').firstMatch(quality);
  if (m == null) return -1;
  return int.tryParse(m.group(1)!) ?? -1;
}

/// Returns [sources] sorted by quality high→low; unknown qualities last.
/// Stable for equal ranks (preserves input order).
List<VideoSource> sortByQuality(List<VideoSource> sources) {
  final indexed = sources.asMap().entries.toList();
  indexed.sort((a, b) {
    final r = qualityRank(
      b.value.quality,
    ).compareTo(qualityRank(a.value.quality));
    return r != 0 ? r : a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// Distinct [AudioKind]s present in [sources], in first-seen order.
List<AudioKind> availableKinds(List<VideoSource> sources) {
  final seen = <AudioKind>[];
  for (final s in sources) {
    if (!seen.contains(s.kind)) seen.add(s.kind);
  }
  return seen;
}

/// Only the sources matching [kind].
List<VideoSource> sourcesForKind(List<VideoSource> sources, AudioKind kind) =>
    sources.where((s) => s.kind == kind).toList();

/// Best default source: highest quality of [prefer]; if none of that kind,
/// highest quality overall. Null only when [sources] is empty.
VideoSource? pickDefault(
  List<VideoSource> sources, {
  AudioKind prefer = AudioKind.sub,
}) {
  if (sources.isEmpty) return null;
  final preferred = sortByQuality(sourcesForKind(sources, prefer));
  if (preferred.isNotEmpty) return preferred.first;
  return sortByQuality(sources).first;
}
