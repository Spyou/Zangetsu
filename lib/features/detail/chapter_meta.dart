import '../../core/models/episode.dart';

/// Line 2 of a chapter row in reading (manga/novel) mode.
///
/// The design calls for `scanlator · relative date`, but [Episode] is shared
/// with the video path and carries no scanlator — Mihon's `SChapter.scanlator`
/// is folded into [Episode.id] by `episodeFromSChapter` and never surfaced as
/// a display field (adding one would mean editing a shared model). So today
/// this is the date half only. The seam is the list below: when a scanlator
/// ever reaches the model, add it as the first entry and the join handles the
/// rest, including the "drop the half we don't have" behaviour.
///
/// Returns null when there's nothing to show, so the caller can drop the whole
/// line and let the row shrink.
String? chapterMetaLine(Episode ep, {DateTime? now}) {
  final parts = <String>[
    // ?scanlator,   ← the seam (see above)
    ?relativeDate(ep.date, now: now),
  ];
  return parts.isEmpty ? null : parts.join('  ·  ');
}

/// "2 days ago" for anything we can parse as a date; the raw string verbatim
/// when we can't (sources hand us all sorts of formats and showing theirs
/// beats showing nothing); null for empty/absent.
String? relativeDate(String? raw, {DateTime? now}) {
  final s = raw?.trim();
  if (s == null || s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  if (d == null) return s;

  final days = (now ?? DateTime.now()).difference(d).inDays;
  // ponytail: whole-day buckets only. Good enough for a chapter list; swap in
  // intl if this ever needs localising.
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days days ago';
  if (days < 30) return _plural(days ~/ 7, 'week');
  if (days < 365) return _plural(days ~/ 30, 'month');
  return _plural(days ~/ 365, 'year');
}

String _plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';
