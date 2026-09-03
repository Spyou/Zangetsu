import '../../../core/models/home_row.dart';
import '../../../core/models/provider_info.dart';
import '../../../core/models/watch_status.dart';
import '../../../core/tracker/tracker.dart';
import '../../../core/tracker/tracker_hub.dart';
import '../../../core/zmode/zmode_ids.dart';

/// The tracker side of the home rows: which tracker answers a layout, and how
/// its library slices into rows. Everything here is pure except
/// [pickHomeTracker], which reads connection state.

/// Which tracker answers for [kind], or null for no tracker rows at all.
///
/// [preferred] is the layout's own provider (`layoutTrackerName`), and it must
/// answer for itself: a MAL home reads MAL's lists or shows none. Substituting
/// another account was misleading — the TMDB home has no account of its own,
/// so it quietly served Simkl's lists under a "From your lists" heading that
/// had nothing to do with what you were browsing. Not signed in, or nothing of
/// that kind, now means no rows rather than someone else's.
///
/// Only a source-backed home passes no preference; there is no provider to
/// name, so hub order (AniList → MAL → Simkl) decides.
Tracker? pickHomeTracker(TrackerHub hub, ZKind kind, {String? preferred}) {
  for (final t in hub.trackers) {
    if (!t.isConnected || !trackerServesKind(t, kind)) continue;
    if (preferred == null || t.displayName == preferred) return t;
  }
  return null;
}

bool trackerServesKind(Tracker t, ZKind kind) => switch (kind) {
  // Everyone carries an anime library.
  ZKind.anime => true,
  // Reading works only where a reading library exists.
  ZKind.manga || ZKind.novel => t.supportsReading,
  // Only Simkl has movie/series lists.
  ZKind.movie || ZKind.tv => t.displayName == 'Simkl',
};

/// `fetchList()` returns everything a tracker holds — this narrows it to the
/// kind being browsed, following each item's own type (Simkl types movies and
/// series alike as movie; `tmdbIsTv` splits them where it matters).
bool itemMatchesKind(TrackerListItem e, ZKind kind) => switch (kind) {
  ZKind.anime => e.item.type == ProviderType.anime,
  ZKind.manga => e.item.type == ProviderType.manga,
  ZKind.novel => e.item.type == ProviderType.novel,
  ZKind.movie || ZKind.tv => e.item.type == ProviderType.movie,
};

/// Episodes/chapters released so far: one behind the next airing episode
/// while a show airs, the total once it's done, 0 when unknown.
int releasedCount(TrackerListItem e) => e.nextAiringEpisode != null
    ? e.nextAiringEpisode! - 1
    : e.totalEpisodes ?? 0;

/// Whether a new episode exists beyond the user's progress. Reading has no
/// equivalent; a movie is one-shot, so only series count in video kinds.
bool hasNewEpisode(TrackerListItem e, ZKind kind) {
  if (kind == ZKind.manga || kind == ZKind.novel) return false;
  if (releasedCount(e) <= (e.progress ?? 0)) return false;
  if (kind == ZKind.movie || kind == ZKind.tv) return e.item.tmdbIsTv;
  return true;
}

int _byUpdatedDesc(TrackerListItem a, TrackerListItem b) =>
    (b.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
      a.updatedAt?.millisecondsSinceEpoch ?? 0,
    );

/// Slice a whole-library [fetchList] result into the non-empty tracker rows,
/// in [trackerRowIds] order. Empty buckets are omitted here, so a layout that
/// enables them still shows nothing until there is something to show.
List<HomeRow> buildTrackerHomeRows({
  required String trackerName,
  required List<TrackerListItem> library,
  required ZKind kind,
}) {
  final byStatus = <WatchStatus, List<TrackerListItem>>{};
  for (final e in library) {
    if (!itemMatchesKind(e, kind)) continue;
    byStatus.putIfAbsent(e.status, () => []).add(e);
  }
  final watching = [
    ...byStatus[WatchStatus.watching] ?? const <TrackerListItem>[],
  ]..sort(_byUpdatedDesc);

  final rows = <HomeRow>[];
  // Continue on the tracker: in progress, past episode/chapter 0.
  final continueItems = watching
      .where((e) => (e.progress ?? 0) > 0)
      .toList(growable: false);
  if (continueItems.isNotEmpty) {
    rows.add(
      TrackerContinueHomeRow(items: continueItems, trackerName: trackerName),
    );
  }
  // New episodes waiting: released beyond progress.
  final fresh = watching.where((e) => hasNewEpisode(e, kind)).toList();
  if (fresh.isNotEmpty) {
    rows.add(NewEpisodesHomeRow(items: fresh, trackerName: trackerName));
  }
  // The status buckets, in default order.
  for (final s in trackerListRowStatuses) {
    final items = byStatus[s];
    if (items == null || items.isEmpty) continue;
    rows.add(
      TrackerListHomeRow(status: s, items: items, trackerName: trackerName),
    );
  }
  return rows;
}
