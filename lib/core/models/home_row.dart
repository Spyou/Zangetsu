import 'home_section.dart';
import 'watch_status.dart';
import '../tracker/tracker.dart';

/// One row of the customizable home screen, in the arrangement the user saved
/// (Settings → Interface → Home rows). Sealed so phone and TV render by type
/// and can't fall through an unhandled case, while the row's persistence id
/// stays a plain string the editor and prefs layer never need to subtype.
sealed class HomeRow {
  const HomeRow();

  /// Stable persistence id: `'local:continue'`, `'tracker:<status>'`,
  /// `'section:<catalogue row title>'`. Section titles are the catalogue's
  /// own English strings, stable per provider, and scoped by the layout key.
  String get id;
}

/// The local Continue Watching / Continue Reading row, driven by the watch /
/// read history box exactly as before this feature existed. Always emitted —
/// the widget self-gates on sign-in and history (it vanishes on its own).
class LocalContinueHomeRow extends HomeRow {
  const LocalContinueHomeRow();

  @override
  String get id => localContinueRowId;
}

/// A provider-defined browse row (AniList / MAL / TMDB / Simkl / CloudStream
/// section). Wraps the section unchanged.
class ProviderHomeRow extends HomeRow {
  const ProviderHomeRow(this.section);

  final HomeSection section;

  @override
  String get id => 'section:${section.title}';
}

/// In-progress entries of the connected tracker — "continue on the tracker":
/// watching/reading entries with progress, most recently updated first.
class TrackerContinueHomeRow extends HomeRow {
  const TrackerContinueHomeRow({
    required this.items,
    required this.trackerName,
  });

  final List<TrackerListItem> items;

  /// Which tracker answered (e.g. "AniList"), for the row's subtitle and for
  /// opening the entry against the right provider.
  final String trackerName;

  @override
  String get id => trackerContinueRowId;
}

/// Watching entries that have released episodes the user hasn't seen — new
/// episodes waiting. Only exists for anime/video layouts (episodes are the
/// unit); reading has no equivalent.
class NewEpisodesHomeRow extends HomeRow {
  const NewEpisodesHomeRow({
    required this.items,
    required this.trackerName,
  });

  final List<TrackerListItem> items;
  final String trackerName;

  @override
  String get id => newEpisodesRowId;
}

/// One status bucket of the connected tracker's library (watching, planning,
/// paused, dropped). The ids are status-based; the reading modes relabel them
/// in the UI ("Reading", "Plan to read") without changing what's stored.
class TrackerListHomeRow extends HomeRow {
  const TrackerListHomeRow({
    required this.status,
    required this.items,
    required this.trackerName,
  });

  final WatchStatus status;
  final List<TrackerListItem> items;
  final String trackerName;

  @override
  String get id => 'tracker:${status.name}';
}

// ── Fixed row ids ───────────────────────────────────────────────────────────
// Constants (not getters on the classes) so the composer and editor can build
// the available-id list without instantiating rows.

const String localContinueRowId = 'local:continue';
const String trackerContinueRowId = 'tracker:continue';
const String newEpisodesRowId = 'tracker:new-episodes';

/// Statuses that get a row, in default order. Completed is deliberately not
/// one of them: it's the whole backlog, unbounded and rarely browsed from a
/// home screen.
const List<WatchStatus> trackerListRowStatuses = [
  WatchStatus.watching,
  WatchStatus.planning,
  WatchStatus.paused,
  WatchStatus.dropped,
];

/// Every tracker-driven row id, in default order — continue and new episodes
/// first, then the status buckets. Derived, not retyped, so the two lists
/// can't drift apart.
final List<String> trackerRowIds = [
  trackerContinueRowId,
  newEpisodesRowId,
  for (final s in trackerListRowStatuses) 'tracker:${s.name}',
];

/// Whether [id] is one of the tracker rows (they default to hidden and only
/// exist where a tracker can answer).
bool isTrackerRowId(String id) => id.startsWith('tracker:');
