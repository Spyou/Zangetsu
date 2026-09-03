import 'package:flutter/material.dart';

import '../../core/models/home_row.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/poster_card.dart';
import '../../l10n/l10n.dart';
import 'cubit/tracker_home_rows.dart' show releasedCount;

/// The tracker-driven rows of the customizable home. All three are [PosterCard]
/// rows on one cell size, so "From your lists" reads as a single block, and
/// none of them draws a progress bar: a tracker knows how many episodes you
/// finished, never where you paused inside one. The local Continue Watching
/// row keeps the landscape card with the bar, because it is the only row with
/// real playback history behind it.
///
/// They render only what the cubit already sliced into [HomeRow]s; nothing
/// here fetches, sorts or filters. The items are metadata stubs: [onOpen]
/// resolves them to a Detail page (or a search fallback) the same way My List
/// opens a tracker entry.

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

/// Whether everything that has actually aired has been seen.
///
/// Only decidable when the tracker sent a next-airing episode — AniList does,
/// MAL and Simkl don't — so on those this stays false and the caption falls
/// back to the plain fraction rather than guessing.
bool trackerCaughtUp(TrackerListItem e) =>
    e.nextAiringEpisode != null && (e.progress ?? 0) >= releasedCount(e);

/// The caption under a "continue on the tracker" card.
///
/// The season total alone can't tell you where you stand: a 10-episode season
/// six episodes in reads `EP 6/10`, which looks like four are waiting when
/// none of them have aired. Say so instead when there's nothing left to watch.
String trackerContinueCaption(BuildContext context, TrackerListItem e) =>
    trackerCaughtUp(e)
    ? context.l10n.trackerCaughtUp
    : trackerProgressSubtitle(e);

/// The poster geometry every tracker row shares — art at 2:3 plus the gap and
/// two lines of caption. Keeping the three rows on one cell size is what makes
/// "From your lists" read as one block instead of three components.
const double _kTrackerCell = 116;
const double _kTrackerCellHeight = 216;

/// "Continue on the tracker": in-progress entries, most recently updated first.
///
/// A poster, not the landscape card the local Continue Watching row uses, and
/// deliberately with no progress bar. A tracker knows how many episodes you
/// finished, never where you paused inside one — drawing that count as a bar
/// made it look like a playback position it can't be. The count lives in the
/// caption, where it reads as what it is.
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
      itemWidth: _kTrackerCell,
      itemHeight: _kTrackerCellHeight,
      itemCount: items.length,
      itemBuilder: (c, i) => _TrackerPosterCard(
        entry: items[i],
        caption: trackerContinueCaption(c, items[i]),
        captionColor: AppColors.textSecondary,
        onTap: () => onOpen(items[i]),
      ),
    );
  }
}

/// "New episodes": watching entries with released episodes past the user's
/// progress.
///
/// Same poster as the continue row, plus the one thing this row knows and no
/// other row on Home shows: how much has piled up. The accent count and accent
/// next-episode line are the whole difference between them.
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
      itemWidth: _kTrackerCell,
      itemHeight: _kTrackerCellHeight,
      itemCount: items.length,
      itemBuilder: (c, i) => _TrackerPosterCard(
        entry: items[i],
        caption: trackerNextSubtitle(items[i]),
        captionColor: AppColors.accent,
        captionBold: true,
        badge: _WaitingBadge(
          releasedCount(items[i]) - (items[i].progress ?? 0),
        ),
        onTap: () => onOpen(items[i]),
      ),
    );
  }
}

/// A tracker card: poster art, a caption line, then the title. Shared by both
/// in-progress rows so they stay one component with one deliberate
/// difference — New Episodes carries a [badge], continue carries none.
///
/// No progress bar on either. The local Continue Watching row keeps the
/// landscape card with the bar, because it's the only row that knows a real
/// playback position; everything sourced from a tracker is a count.
class _TrackerPosterCard extends StatelessWidget {
  const _TrackerPosterCard({
    required this.entry,
    required this.caption,
    required this.captionColor,
    required this.onTap,
    this.captionBold = false,
    this.badge,
  });

  final TrackerListItem entry;
  final String caption;
  final Color captionColor;
  final bool captionBold;
  final VoidCallback onTap;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    // The caption and title sit OUTSIDE the poster (it draws neither), so
    // without this the two lines under the art would be dead space. The
    // poster keeps its own onTap for the press animation and wins the arena
    // for taps on the art itself, so nothing fires twice.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _kTrackerCell * 1.5,
            child: Stack(
              children: [
                Positioned.fill(
                  child: PosterCard(
                    title: entry.item.title,
                    imageUrl: entry.item.cover,
                    headers: entry.item.coverHeaders,
                    cellWidth: _kTrackerCell,
                    showTitle: false, // the caption below carries it
                    onTap: onTap,
                  ),
                ),
                // IgnorePointer so the whole card stays one tap target.
                if (badge != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IgnorePointer(child: badge!),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: captionColor,
              fontWeight: captionBold ? FontWeight.w700 : null,
            ),
          ),
          Text(
            entry.item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// How many episodes are waiting. A count rather than a "NEW" label, so one
/// glance separates tonight's episode from a backlog worth an evening.
class _WaitingBadge extends StatelessWidget {
  const _WaitingBadge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.accent,
      borderRadius: BorderRadius.circular(20),
      boxShadow: const [
        BoxShadow(
          color: Color(0x59000000),
          blurRadius: 6,
          offset: Offset(0, 1),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        '+$count',
        style: const TextStyle(
          fontFamily: 'Inter',
          fontFamilyFallback: AppText.fontFamilyFallback,
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
          color: Colors.white,
        ),
      ),
    ),
  );
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
