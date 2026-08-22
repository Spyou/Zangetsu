import '../../core/models/episode.dart';

/// Line 2 of a chapter row in reading (manga/novel) mode.
///
/// Reads `scanlator · relative date`, dropping whichever half is missing —
/// most sources have no scanlator, plenty have no usable date, and a row with
/// neither loses the line entirely.
///
/// Returns null when there's nothing to show, so the caller can drop the whole
/// line and let the row shrink.
String? chapterMetaLine(Episode ep, {DateTime? now}) {
  final parts = <String>[
    // Already normalised at ingest by [scanlatorLabel] — null means no group.
    ?ep.scanlator,
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
