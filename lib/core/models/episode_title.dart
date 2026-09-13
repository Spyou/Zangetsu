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

/// True when [title] is empty or only a generic "Episode N" / "S1 · E2" marker.
bool isGenericEpisodeTitle(String? title, int? number) {
  final t = (title ?? '').trim();
  if (t.isEmpty) return true;
  var cleaned = cleanTitle(t);
  if (number != null) cleaned = stripGenericEpisodePrefix(cleaned, number);
  // Also treat "S1 · E3" / "S1 E3" leftovers after cleanTitle as generic.
  cleaned = cleaned
      .replaceFirst(RegExp(r'^S\d+\s*[·.]\s*E\d+\s*$', caseSensitive: false), '')
      .trim();
  return cleaned.isEmpty;
}

/// Keep catalogue / AniZip / TMDB display fields when a stream-source episode
/// list replaces an already-painted one (same episode numbers).
///
/// Home and Detail read show-level metadata from the user's chosen catalogue
/// (AniList/MAL or TMDB/Simkl). Per-episode names and synopses come from that
/// stack too (AniZip for anime, TMDB seasons for series). The matched source
/// only decides what can play — its "Episode N" labels must not wipe real
/// titles that were already on screen.
List<Episode> carryEpisodeDisplayMeta(
  List<Episode>? previous,
  List<Episode> next,
) {
  if (previous == null || previous.isEmpty || next.isEmpty) return next;
  final byNum = <int, Episode>{
    for (final e in previous)
      if (episodeNumberInt(e) != null) episodeNumberInt(e)!: e,
  };
  if (byNum.isEmpty) return next;

  var changed = false;
  final out = <Episode>[
    for (final e in next)
      () {
        final n = episodeNumberInt(e);
        final prev = n == null ? null : byNum[n];
        if (prev == null) return e;
        final keepTitle = isGenericEpisodeTitle(e.title, n) &&
            !isGenericEpisodeTitle(prev.title, n);
        final merged = e.copyWith(
          title: keepTitle ? prev.title : e.title,
          description: prev.description ?? e.description,
          metaTitle: prev.metaTitle ?? e.metaTitle,
          thumbnail: (prev.thumbnail != null && prev.thumbnail!.isNotEmpty)
              ? prev.thumbnail
              : e.thumbnail,
          date: (prev.date != null && prev.date!.isNotEmpty) ? prev.date : e.date,
          rating: prev.rating ?? e.rating,
          runtimeMinutes: prev.runtimeMinutes ?? e.runtimeMinutes,
          season: e.season ?? prev.season,
        );
        if (!identical(merged, e) &&
            (merged.title != e.title ||
                merged.description != e.description ||
                merged.metaTitle != e.metaTitle ||
                merged.thumbnail != e.thumbnail ||
                merged.date != e.date ||
                merged.rating != e.rating ||
                merged.runtimeMinutes != e.runtimeMinutes ||
                merged.season != e.season)) {
          changed = true;
        }
        return merged;
      }(),
  ];
  return changed ? out : next;
}
