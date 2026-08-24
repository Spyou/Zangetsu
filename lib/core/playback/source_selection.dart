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

/// Approximate vertical resolution (px) named by a quality label. Handles the
/// 4K/2K/FHD shorthand as well as bare numbers. Null when the label names no
/// resolution at all — 'auto', 'highest', or a bare server name like
/// 'Doodstream'.
int? resolutionPx(String? label) {
  if (label == null) return null;
  final l = label.toLowerCase();
  if (l.contains('2160') || l.contains('4k') || l.contains('uhd')) return 2160;
  if (l.contains('1440') || l.contains('2k')) return 1440;
  if (l.contains('1080') || l.contains('fhd')) return 1080;
  if (l.contains('720')) return 720;
  if (l.contains('480')) return 480;
  if (l.contains('360')) return 360;
  if (l.contains('240')) return 240;
  final m = RegExp(r'(\d{3,4})').firstMatch(l);
  return m != null ? int.tryParse(m.group(1)!) : null;
}

/// Best default source: highest quality of [prefer]; if none of that kind,
/// highest quality overall. Null only when [sources] is empty.
///
/// [preferQuality] is the user's saved resolution preference. When it names a
/// real resolution the source closest to it wins, so a provider that ships one
/// stream per quality honours the preference by STARTING on the right stream.
/// Switching streams once playback is already running would be a different
/// file — different server, audio and subtitles — which is never what a
/// quality preference means.
VideoSource? pickDefault(
  List<VideoSource> sources, {
  AudioKind prefer = AudioKind.sub,
  String? preferQuality,
}) {
  if (sources.isEmpty) return null;
  final preferred = sortByQuality(sourcesForKind(sources, prefer));
  final pool = preferred.isNotEmpty ? preferred : sortByQuality(sources);

  final want = resolutionPx(preferQuality);
  if (want != null) {
    VideoSource? best;
    var bestDiff = 1 << 30;
    for (final s in pool) {
      final px = resolutionPx(s.quality);
      if (px == null) continue;
      final d = (px - want).abs();
      // Pool is sorted high->low, so a strict < keeps the HIGHER one on a tie.
      if (d < bestDiff) {
        bestDiff = d;
        best = s;
      }
    }
    if (best != null) return best;
  }
  // 'auto'/'highest', or nothing carried a resolution: the existing default.
  return pool.first;
}
