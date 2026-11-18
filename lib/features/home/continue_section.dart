import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/watch_history.dart';
import '../../core/reading/read_history.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/continue_card.dart';
import '../../core/ui/disintegrating_poster.dart';
import '../../core/ui/placement_slide.dart';

/// Identity for an exiting continue card. Plain `sourceId::showId` — the set
/// only lives for the animation inside this row, so it needs a stable string,
/// not the stores' profile-scoped keys.
String watchGhostKey(HistoryEntry e) => '${e.sourceId}::${e.showId}';
String readGhostKey(ReadEntry e) => '${e.sourceId}::${e.showId}';

/// Home's "Continue Watching" / "Continue Reading" sliver. Anime mode renders
/// the original [WatchHistory]-backed row exactly as before; reading modes
/// (manga/novel) swap in a [ReadHistory]-backed row with the same card chrome.
/// Split out of [_HomeView] purely so it's independently widget-testable —
/// the surrounding Home screen carries update-check/network side effects that
/// have no place in this row's tests.
///
/// Reactive to [ContentModeCubit] (not just re-read once) so flipping modes
/// from Home's own header swaps the row immediately, even when the mode
/// switch doesn't also change the active source (which is what normally
/// triggers a HomeCubit rebuild).
///
/// This widget is just the thin reactive shell (Hive box guard +
/// ValueListenableBuilder); the actual row chrome lives in
/// [ContinueWatchingRow] / [ContinueReadingRow] below, split out so tests can
/// pump the rendered content directly against a resolved list instead of a
/// live Hive box.
class ContinueSection extends StatelessWidget {
  const ContinueSection({
    super.key,
    required this.onResume,
    required this.onLongPress,
    required this.onSeeAll,
    required this.onResumeReading,
    required this.onLongPressReading,
    this.exitingIds = const {},
    this.ghostWatch = const [],
    this.ghostReading = const [],
    this.hiddenIds = const {},
    this.pendingIds = const {},
    this.onExited,
  });

  final void Function(HistoryEntry) onResume;
  final void Function(HistoryEntry) onLongPress;
  final VoidCallback onSeeAll;
  final void Function(ReadEntry) onResumeReading;
  final void Function(ReadEntry) onLongPressReading;

  /// Keys (watchGhostKey/readGhostKey) of cards currently crumbling, with
  /// their ghost entries kept in the row until [onExited] commits the real
  /// removal — same exiting-retention as My List's poster grid.
  final Set<String> exitingIds;
  final List<HistoryEntry> ghostWatch;
  final List<ReadEntry> ghostReading;

  /// Keys (w:/r: prefixed ghost keys) of cards committed but not yet
  /// confirmed gone by the store's reload. Hidden instantly so the slot
  /// closes and neighbours glide right away — instead of waiting out the
  /// store write plus the cloud round-trip.
  final Set<String> hiddenIds;

  /// Keys with a commit currently in flight. A hidden key back in the list
  /// with no commit in flight was re-added — show it again at once.
  final Set<String> pendingIds;
  final void Function(String key)? onExited;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContentModeCubit, ContentMode>(
      bloc: sl<ContentModeCubit>(),
      builder: (context, mode) =>
          mode.isReading ? _readingRow(mode) : _watchingRow(),
    );
  }

  // ── Continue Watching ────────────────────────────────────────────────────

  /// Hides committed-but-unconfirmed removals so the slot closes and
  /// neighbours glide instantly instead of waiting out the store write plus
  /// the cloud round-trip. A hidden key back with no commit in flight was
  /// re-added — show it again. Fast path: with nothing hidden the caller's
  /// list passes straight through.
  List<T> _visible<T>(
    List<T> entries,
    String Function(T) keyOf,
    String prefix,
  ) {
    if (hiddenIds.isEmpty) return entries;
    hiddenIds.removeWhere(
      (k) => libraryKeyVisible(
        commitInFlight: pendingIds.contains(k),
        presentInStore: entries.any((e) => '$prefix${keyOf(e)}' == k),
      ),
    );
    if (hiddenIds.isEmpty) return entries;
    return entries
        .where((e) => !hiddenIds.contains('$prefix${keyOf(e)}'))
        .toList();
  }

  Widget _watchingRow() {
    // Watch history is local too, so signed-out users can continue watching.
    // Keep the box guard so a test or early boot never touches a closed box.
    if (!Hive.isBoxOpen(WatchHistory.boxName)) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return ValueListenableBuilder(
      valueListenable: Hive.box<Map>(WatchHistory.boxName).listenable(),
      builder: (context, _, _) {
        // ONE list, not split by Anime vs Movie/TV. Continue Watching answers
        // "where was I", which has nothing to do with what you are browsing —
        // and it is sorted by most-recent, so the thing you were actually
        // watching is first either way. Splitting it meant checking two tabs
        // to find your place, and the filter that did it read the kind from
        // the SOURCE: rows are saved against the router ("zm"), which is in no
        // repo manifest, so every row returned null and Movie/TV sat empty.
        //
        // Manga and novel stay separate — they are a different store and a
        // different row (Continue READING), routed above by `mode.isReading`.
        final history = sl<WatchHistory>().recent();
        // Ghosts of cards mid-dissolve, re-sorted by recency so each holds
        // its slot instead of jumping to the end.
        final all = [...history];
        for (final g in ghostWatch) {
          if (all.every((e) => watchGhostKey(e) != watchGhostKey(g))) {
            all.add(g);
          }
        }
        all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return ContinueWatchingRow(
          history: _visible(all, watchGhostKey, 'w::'),
          onSeeAll: onSeeAll,
          onResume: onResume,
          onLongPress: onLongPress,
          exitingIds: exitingIds,
          onExited: onExited,
        );
      },
    );
  }

  // ── Continue Reading (manga/novel) ────────────────────────────────────────

  Widget _readingRow(ContentMode mode) {
    if (!Hive.isBoxOpen(ReadHistory.boxName)) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    // Only this mode's kind — the ReadHistory box mixes manga and novel.
    final type = mode == ContentMode.manga
        ? ProviderType.manga
        : ProviderType.novel;
    return ValueListenableBuilder(
      valueListenable: Hive.box<Map>(ReadHistory.boxName).listenable(),
      builder: (context, _, _) {
        final history = sl<ReadHistory>().recent(type: type);
        final all = [...history];
        for (final g in ghostReading) {
          if (all.every((e) => readGhostKey(e) != readGhostKey(g))) {
            all.add(g);
          }
        }
        all.sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
        return ContinueReadingRow(
          history: _visible(all, readGhostKey, 'r::'),
          onResumeReading: onResumeReading,
          onLongPress: onLongPressReading,
          onSeeAll: onSeeAll,
          exitingIds: exitingIds,
          onExited: onExited,
        );
      },
    );
  }
}

/// Continue Watching row content, given an already-resolved [history] list —
/// no Hive access of its own. Identical chrome to the original inline row.
class ContinueWatchingRow extends StatelessWidget {
  const ContinueWatchingRow({
    super.key,
    required this.history,
    required this.onSeeAll,
    required this.onResume,
    required this.onLongPress,
    this.exitingIds = const {},
    this.onExited,
  });

  final List<HistoryEntry> history;
  final VoidCallback onSeeAll;
  final void Function(HistoryEntry) onResume;
  final void Function(HistoryEntry) onLongPress;
  final Set<String> exitingIds;
  final void Function(String key)? onExited;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: ContentRow(
        title: 'Continue Watching',
        // Compact 16:9 landscape card — same design, just smaller/tighter.
        itemWidth: 190,
        itemHeight: 107,
        onSeeAll: onSeeAll,
        itemCount: history.length,
        itemKeys: [for (final e in history) watchGhostKey(e)],
        itemBuilder: (c, i) {
          final e = history[i];
          final key = watchGhostKey(e);
          final exiting = exitingIds.contains(key) && onExited != null;
          Widget card = ContinueCard(
            title: e.showTitle,
            // Prefer the landscape episode thumbnail; fall back to the
            // portrait cover (older entries / sources without them).
            imageUrl: e.thumbnail ?? e.cover,
            headers: e.coverHeaders,
            progress: e.progress,
            cellWidth: 190,
            subtitle: e.episodeNumber != null
                ? 'Episode ${e.episodeNumber!.toInt()}'
                : null,
            onTap: () => onResume(e),
            onLongPress: () => onLongPress(e),
          );
          if (exiting) {
            card = DisintegratingPoster(
              disintegrating: true,
              borderRadius: 14,
              onDisintegrated: () => onExited!(key),
              child: card,
            );
          }
          return card;
        },
      ),
    );
  }
}

/// Continue Reading row content, given an already-resolved [history] list —
/// no Hive access of its own.
class ContinueReadingRow extends StatelessWidget {
  const ContinueReadingRow({
    super.key,
    required this.history,
    required this.onResumeReading,
    this.onLongPress,
    this.onSeeAll,
    this.exitingIds = const {},
    this.onExited,
  });

  final List<ReadEntry> history;
  final void Function(ReadEntry) onResumeReading;
  final void Function(ReadEntry)? onLongPress;
  final VoidCallback? onSeeAll;
  final Set<String> exitingIds;
  final void Function(String key)? onExited;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: ContentRow(
        title: 'Continue Reading',
        // Compact horizontal "keep reading" chip (cover + title + chapter +
        // slim progress bar, NOT the landscape Continue Watching card nor a
        // full portrait poster — smaller and its own shape for reading.
        itemWidth: 236,
        itemHeight: 76,
        onSeeAll: onSeeAll,
        itemCount: history.length,
        itemKeys: [for (final e in history) readGhostKey(e)],
        itemBuilder: (c, i) {
          final e = history[i];
          final key = readGhostKey(e);
          final exiting =
              exitingIds.contains(key) &&
              onExited != null &&
              onLongPress != null;
          final progress = e.total > 0
              ? (e.pos / e.total).clamp(0.0, 1.0)
              : 0.0;
          Widget card = ContinueReadingCard(
            title: e.title,
            imageUrl: e.cover,
            headers: e.coverHeaders,
            progress: progress,
            subtitle: e.chapterNumber != null
                ? 'Chapter ${e.chapterNumber!.toInt()}'
                : null,
            onTap: () => onResumeReading(e),
            onLongPress: onLongPress == null ? null : () => onLongPress!(e),
          );
          if (exiting) {
            card = DisintegratingPoster(
              disintegrating: true,
              onDisintegrated: () => onExited!(key),
              child: card,
            );
          }
          return card;
        },
      ),
    );
  }
}
