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
    required this.loggedIn,
    required this.onResume,
    required this.onLongPress,
    required this.onSeeAll,
    required this.onResumeReading,
    required this.onLongPressReading,
  });

  final bool loggedIn;
  final void Function(HistoryEntry) onResume;
  final void Function(HistoryEntry) onLongPress;
  final VoidCallback onSeeAll;
  final void Function(ReadEntry) onResumeReading;
  final void Function(ReadEntry) onLongPressReading;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContentModeCubit, ContentMode>(
      bloc: sl<ContentModeCubit>(),
      builder: (context, mode) =>
          mode.isReading ? _readingRow(mode) : _watchingRow(),
    );
  }

  // ── Continue Watching (anime) — PRESERVED EXACTLY ─────────────────────────

  Widget _watchingRow() {
    // Login-gated, and guarded so a signed-out render (or the test env) never
    // touches the box — production opens it at boot.
    if (!(loggedIn && Hive.isBoxOpen(WatchHistory.boxName))) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return ValueListenableBuilder(
      valueListenable: Hive.box<Map>(WatchHistory.boxName).listenable(),
      builder: (context, _, _) => ContinueWatchingRow(
        history: sl<WatchHistory>().recent(),
        onSeeAll: onSeeAll,
        onResume: onResume,
        onLongPress: onLongPress,
      ),
    );
  }

  // ── Continue Reading (manga/novel) ────────────────────────────────────────

  Widget _readingRow(ContentMode mode) {
    if (!(loggedIn && Hive.isBoxOpen(ReadHistory.boxName))) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    // Only this mode's kind — the ReadHistory box mixes manga and novel.
    final type =
        mode == ContentMode.manga ? ProviderType.manga : ProviderType.novel;
    return ValueListenableBuilder(
      valueListenable: Hive.box<Map>(ReadHistory.boxName).listenable(),
      builder: (context, _, _) => ContinueReadingRow(
        history: sl<ReadHistory>().recent(type: type),
        onResumeReading: onResumeReading,
        onLongPress: onLongPressReading,
        onSeeAll: onSeeAll,
      ),
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
  });

  final List<HistoryEntry> history;
  final VoidCallback onSeeAll;
  final void Function(HistoryEntry) onResume;
  final void Function(HistoryEntry) onLongPress;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: ContentRow(
          title: 'Continue Watching',
          // Compact 16:9 landscape card — same design, just smaller/tighter.
          itemWidth: 190,
          itemHeight: 107,
          onSeeAll: onSeeAll,
          itemCount: history.length,
          itemBuilder: (c, i) {
            final e = history[i];
            return ContinueCard(
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
          },
        ),
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
  });

  final List<ReadEntry> history;
  final void Function(ReadEntry) onResumeReading;
  final void Function(ReadEntry)? onLongPress;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: ContentRow(
          title: 'Continue Reading',
          // Compact horizontal "keep reading" chip (cover + title + chapter +
          // slim progress), NOT the landscape Continue Watching card nor a full
          // portrait poster — smaller and its own shape for reading.
          itemWidth: 236,
          itemHeight: 76,
          onSeeAll: onSeeAll,
          itemCount: history.length,
          itemBuilder: (c, i) {
            final e = history[i];
            final progress =
                e.total > 0 ? (e.pos / e.total).clamp(0.0, 1.0) : 0.0;
            return ContinueReadingCard(
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
          },
        ),
      ),
    );
  }
}
