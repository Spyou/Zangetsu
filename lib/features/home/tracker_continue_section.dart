import 'package:flutter/material.dart';

import '../../core/models/home_row.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/tracker/tracker.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/continue_card.dart';
import '../../core/ui/poster_card.dart';
import '../../l10n/l10n.dart';

/// The tracker-driven rows of the customizable home. All three reuse the row
/// chrome Home already has — [ContinueCard]'s landscape card for the
/// in-progress rows, [PosterCard] for the status rows — and render only what
/// the cubit already sliced into [HomeRow]s; nothing here fetches, sorts or
/// filters. The items are metadata stubs: [onOpen] resolves them to a Detail
/// page (or a search fallback) the same way My List opens a tracker entry.

/// What a tap on a tracker entry does. Kept as one typedef so the three rows
/// stay interchangeable in tests.
typedef TrackerEntryOpen = void Function(TrackerListItem entry);

// ── Shared tracker-row bits (phone rows AND TV rails) ────────────────────────
// One definition each so the two platforms can't drift; row titles come from
// the l10n keys (homeRowTrackerContinue / homeRowNewEpisodes), status labels
// reuse the statusX keys.

/// Whether a row's entries are reading titles — every row picks its unit
/// ("Ch" vs "EP") and its labels from the items themselves, so phone and TV
// agree without passing a mode around.
bool trackerEntryIsReading(TrackerListItem e) =>
    e.item.type == ProviderType.manga || e.item.type == ProviderType.novel;

/// A status bucket's label, relabeling the bookends in a reading layout
/// ("Reading", "Plan to Read").
String trackerStatusLabel(
  BuildContext context,
  WatchStatus status, {
  required bool reading,
}) => switch (status) {
  WatchStatus.watching =>
    reading ? context.l10n.statusReading : context.l10n.statusWatching,
  WatchStatus.planning =>
    reading ? context.l10n.statusPlanToRead : context.l10n.statusPlanning,
  WatchStatus.paused => context.l10n.statusPaused,
  WatchStatus.dropped => context.l10n.statusDropped,
  WatchStatus.completed => context.l10n.statusCompleted,
};

/// Resume progress in [0, 1]; 0 when the total is unknown (no total means no
/// honest fraction at all).
double trackerResumeFraction(TrackerListItem e) {
  final total = e.totalEpisodes ?? 0;
  return total > 0 ? ((e.progress ?? 0) / total).clamp(0.0, 1.0) : 0;
}

/// `EP 4/12` (or `Ch 12/104` in a reading row); the count alone when the
/// tracker didn't send a total.
String trackerProgressSubtitle(TrackerListItem e) {
  final unit = trackerEntryIsReading(e) ? 'Ch' : 'EP';
  final total = e.totalEpisodes;
  return total != null && total > 0
      ? '$unit ${e.progress ?? 0}/$total'
      : '$unit ${e.progress ?? 0}';
}

/// The episode waiting next: one past the user's progress.
String trackerNextSubtitle(TrackerListItem e) => trackerEntryIsReading(e)
    ? 'Ch ${(e.progress ?? 0) + 1}'
    : 'EP ${(e.progress ?? 0) + 1}';

/// "Continue on the tracker": in-progress entries, most recently updated first.
/// Same compact 16:9 card as the local Continue Watching row — the progress
/// bar and EP/Ch badge tell the two apart at a glance.
class TrackerContinueSection extends StatelessWidget {
  const TrackerContinueSection({
    super.key,
    required this.items,
    required this.trackerName,
    required this.onOpen,
  });

  final List<TrackerListItem> items;
  final String trackerName;
  final TrackerEntryOpen onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return ContentRow(
      title: context.l10n.homeRowTrackerContinue(trackerName),
      itemWidth: 190,
      itemHeight: 107,
      itemCount: items.length,
      itemBuilder: (c, i) {
        final e = items[i];
        return ContinueCard(
          title: e.item.title,
          imageUrl: e.item.cover,
          headers: e.item.coverHeaders,
          progress: trackerResumeFraction(e),
          cellWidth: 190,
          subtitle: trackerProgressSubtitle(e),
          onTap: () => onOpen(e),
        );
      },
    );
  }
}

/// "New episodes": watching entries with released episodes past the user's
/// progress. The card points at the NEXT episode; the badge carries the total.
class NewEpisodesSection extends StatelessWidget {
  const NewEpisodesSection({
    super.key,
    required this.items,
    required this.trackerName,
    required this.onOpen,
  });

  final List<TrackerListItem> items;
  final String trackerName;
  final TrackerEntryOpen onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return ContentRow(
      title: context.l10n.homeRowNewEpisodes,
      overline: trackerName,
      itemWidth: 190,
      itemHeight: 107,
      itemCount: items.length,
      itemBuilder: (c, i) {
        final e = items[i];
        return ContinueCard(
          title: e.item.title,
          imageUrl: e.item.cover,
          headers: e.item.coverHeaders,
          progress: trackerResumeFraction(e),
          cellWidth: 190,
          subtitle: trackerNextSubtitle(e),
          onTap: () => onOpen(e),
        );
      },
    );
  }
}

/// One status bucket of the tracker's library — same poster row as a provider
/// browse row, so "your lists" and "discover" read as one screen.
class TrackerListSection extends StatelessWidget {
  const TrackerListSection({
    super.key,
    required this.status,
    required this.items,
    required this.trackerName,
    required this.onOpen,
  });

  final WatchStatus status;
  final List<TrackerListItem> items;
  final String trackerName;
  final TrackerEntryOpen onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    // Reading rows relabel the bookends ("Reading", "Plan to Read"); the
    // bucket itself is decided by each item's own type, like every other
    // kind split in the tracker rows.
    final reading = trackerEntryIsReading(items.first);
    return ContentRow(
      title: trackerStatusLabel(context, status, reading: reading),
      overline: trackerName,
      itemWidth: 116,
      itemHeight: 216,
      itemCount: items.length,
      itemBuilder: (c, i) {
        final e = items[i];
        return PosterCard(
          title: e.item.title,
          imageUrl: e.item.cover,
          headers: e.item.coverHeaders,
          cellWidth: 116,
          onTap: () => onOpen(e),
        );
      },
    );
  }
}
