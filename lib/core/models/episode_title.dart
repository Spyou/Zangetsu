import 'episode.dart';

/// Strip a leading `S1 E3 -` prefix so multi-season source titles show a
/// clean name. No-op when the title has no such prefix.
String cleanTitle(String title) {
  return title.replaceFirst(RegExp(r'^S\d+\s+E\d+\s*[-–—]?\s*'), '').trim();
}

/// Drop a leading generic "Episode 12" / "Ep. 12" / "E12" / "12." marker.
/// Empty result means the source title was only that marker.
String stripGenericEpisodePrefix(String title, int n) {
  final t = title.trim();
  final word = RegExp(
    '^(?:episode|ep\\.?|e)\\s*0*$n(?![0-9])\\s*[:\\-–—.)\\]]*\\s*',
    caseSensitive: false,
  );
  final bare = RegExp('^0*$n(?![0-9])\\s*[:\\-–—.)\\]]+\\s*');
  final m = word.firstMatch(t) ?? bare.firstMatch(t);
  if (m == null) return t;
  return t.substring(m.end).trim();
}

int? episodeNumberInt(Episode ep) {
  final n = ep.number;
  if (n == null || n != n.roundToDouble()) return null;
  return n.toInt();
}

/// Visible episode name: source title when it is real, else AniZip/TMDB
/// [Episode.metaTitle]. Generic "Episode N" source titles do not count.
String? episodeDisplayTitle(Episode ep, {String? sourceTitle, int? number}) {
  final n = number ?? episodeNumberInt(ep);
  var src = (sourceTitle ?? ep.title).trim();
  src = cleanTitle(src);
  if (n != null) src = stripGenericEpisodePrefix(src, n);
  if (src.isNotEmpty) return src;
  var meta = ep.metaTitle?.trim() ?? '';
  if (meta.isEmpty) return null;
  meta = cleanTitle(meta);
  if (n != null) meta = stripGenericEpisodePrefix(meta, n);
  return meta.isEmpty ? null : meta;
}

/// Player / Discord details line: `Episode 47 · The Title`, or `Episode 47`
/// when no real name is known.
String? episodePresenceDetails(Episode ep, {int? fallbackNumber}) {
  final n = episodeNumberInt(ep) ?? fallbackNumber;
  final title = episodeDisplayTitle(ep, number: n);
  if (n == null) return title;
  if (title == null) return 'Episode $n';
  return 'Episode $n · $title';
}
