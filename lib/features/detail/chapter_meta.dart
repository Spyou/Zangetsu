import '../../core/models/episode.dart';
import '../../l10n/app_localizations.dart';

/// Line 2 of a chapter row in reading (manga/novel) mode.
///
/// Reads `scanlator · relative date`, dropping whichever half is missing —
/// most sources have no scanlator, plenty have no usable date, and a row with
/// neither loses the line entirely.
///
/// Returns null when there's nothing to show, so the caller can drop the whole
/// line and let the row shrink.
String? chapterMetaLine(AppLocalizations l10n, Episode ep, {DateTime? now}) {
  final parts = <String>[
    // Already normalised at ingest by [scanlatorLabel] — null means no group.
    ?ep.scanlator,
    ?relativeDate(l10n, ep.date, now: now),
  ];
  return parts.isEmpty ? null : parts.join('  ·  ');
}

/// "2 days ago" for anything we can parse as a date; the raw string verbatim
/// when we can't (sources hand us all sorts of formats and showing theirs
/// beats showing nothing); null for empty/absent.
String? relativeDate(AppLocalizations l10n, String? raw, {DateTime? now}) {
  final s = raw?.trim();
  if (s == null || s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  if (d == null) return s;

  final days = (now ?? DateTime.now()).difference(d).inDays;
  if (days <= 0) return l10n.relativeToday;
  if (days == 1) return l10n.relativeYesterday;
  if (days < 7) return l10n.relativeDaysAgo(days);
  if (days < 30) return l10n.relativeWeeksAgo(days ~/ 7);
  if (days < 365) return l10n.relativeMonthsAgo(days ~/ 30);
  return l10n.relativeYearsAgo(days ~/ 365);
}
