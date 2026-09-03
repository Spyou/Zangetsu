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
      title: 'Continue on $trackerName',
      itemWidth: 190,
      itemHeight: 107,
      itemCount: items.length,
      itemBuilder: (c, i) {
        final e = items[i];
        return ContinueCard(
          title: e.item.title,
          imageUrl: e.item.cover,
          headers: e.item.coverHeaders,
          progress: _progress(e),
          cellWidth: 190,
          subtitle: _progressSubtitle(e),
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
      title: 'New Episodes',
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
          progress: _progress(e),
          cellWidth: 190,
          subtitle: _nextSubtitle(e),
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
    // Reading layouts relabel the bookends ("Reading", "Plan to Read"); the
    // bucket itself is decided by each item's own type, like every other
    // kind split in the tracker rows.
    final reading = _isReading(items.first.item.type);
    return ContentRow(
      title: switch (status) {
        WatchStatus.watching =>
          reading ? context.l10n.statusReading : context.l10n.statusWatching,
        WatchStatus.planning =>
          reading ? context.l10n.statusPlanToRead : context.l10n.statusPlanning,
        WatchStatus.paused => context.l10n.statusPaused,
        WatchStatus.dropped => context.l10n.statusDropped,
        WatchStatus.completed => context.l10n.statusCompleted,
      },
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

// ── Shared item bits ─────────────────────────────────────────────────────────

bool _isReading(ProviderType t) =>
    t == ProviderType.manga || t == ProviderType.novel;

/// Resume progress in [0, 1]; 0 when the total is unknown (a bare bar would
/// lie less than a full one, but no total means no honest fraction at all).
double _progress(TrackerListItem e) {
  final total = e.totalEpisodes ?? 0;
  return total > 0 ? ((e.progress ?? 0) / total).clamp(0.0, 1.0) : 0;
}

/// `EP 4/12` (or `Ch 12/104` in a reading layout); the count alone when the
/// tracker didn't send a total.
String _progressSubtitle(TrackerListItem e) {
  final unit = _isReading(e.item.type) ? 'Ch' : 'EP';
  final total = e.totalEpisodes;
  return total != null && total > 0
      ? '$unit ${e.progress ?? 0}/$total'
      : '$unit ${e.progress ?? 0}';
}

/// The episode waiting next: one past the user's progress.
String _nextSubtitle(TrackerListItem e) => _isReading(e.item.type)
    ? 'Ch ${(e.progress ?? 0) + 1}'
    : 'EP ${(e.progress ?? 0) + 1}';
