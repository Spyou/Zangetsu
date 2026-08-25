import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_poster_tile.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/states.dart';
import '../../core/ui/tracker_entry_sheet.dart';
import '../detail/detail_screen.dart';
import 'cubit/my_list_cubit.dart';
import 'cubit/tracker_list_cubit.dart';
import 'search_screen.dart';

/// TV My List: a full-screen focusable poster grid backed by [MyListCubit]
/// (own list) and [TrackerListCubit] (AniList / MAL / Simkl when connected).
///
/// Reuses the phone's cubits unchanged. Only the interaction model changes:
/// each card is wrapped in [TvFocusable] so the D-pad navigates the grid, OK
/// opens Detail (or Search for tracker stubs), and a held OK opens the same
/// status/remove sheet as the phone long-press. A chip row switches between
/// My List and each connected tracker — same sources as the phone segmented
/// control. The rail↔content focus bridge in [RootShellTv] already handles
/// LEFT-at-edge → rail.
class MyListScreenTv extends StatelessWidget {
  const MyListScreenTv({super.key});

  /// 6 columns keeps the cards near the home-rail ~140 dp scale on a 1080p TV
  /// (matches the see-all grid; 5 rendered them oversized).
  static const int _crossAxisCount = 6;

  Future<void> _openOwnItem(BuildContext context, MediaItem item) async {
    final cubit = context.read<MyListCubit>();
    await Navigator.push(context, DetailScreen.route(item));
    cubit.reload();
  }

  void _openTrackerItem(BuildContext context, MediaItem stub) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialQuery: stub.title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: BlocBuilder<TrackerListCubit, TrackerListState>(
          builder: (context, tlState) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                  child: Text('My List', style: AppText.largeTitle),
                ),
                _SourceChips(tlState: tlState),
                // Gap so poster float rings (scale + outer outline) don't paint
                // up under the source chips — Column paints the grid AFTER the
                // chips, so any upward bleed covers the chip focus chrome.
                const SizedBox(height: 8),
                Expanded(
                  child: tlState.isMyList
                      ? _ownListBody(context)
                      : _trackerBody(context, tlState),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _ownListBody(BuildContext context) {
    return BlocBuilder<MyListCubit, List<MyListEntry>>(
      builder: (context, entries) {
        if (entries.isEmpty) {
          return const EmptyState(
            icon: Icons.bookmark_outline,
            message: 'Titles you add appear here',
          );
        }
        // Chips take autofocus when present; otherwise first poster.
        final chipsVisible = _connectedTrackers().isNotEmpty;
        return _posterGrid(
          entries: entries,
          autofocusFirst: !chipsVisible,
          onTap: (item) => _openOwnItem(context, item),
          onLongPress: (entry) {
            final cubit = context.read<MyListCubit>();
            showListStatusSheet(
              context,
              item: entry.item,
              onChanged: cubit.reload,
            );
          },
        );
      },
    );
  }

  Widget _trackerBody(BuildContext context, TrackerListState tlState) {
    switch (tlState.status) {
      case TrackerListStatus.loading:
        return Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        );
      case TrackerListStatus.error:
        return const EmptyState(
          icon: Icons.cloud_off_rounded,
          message: 'Couldn’t load — try again from Settings',
        );
      case TrackerListStatus.idle:
      case TrackerListStatus.ready:
        if (tlState.entries.isEmpty) {
          return const EmptyState(
            icon: Icons.bookmark_outline,
            message: 'No titles in this list',
          );
        }
        final tracker = tlState.tracker!;
        return _posterGrid(
          entries: tlState.entries,
          autofocusFirst: false,
          onTap: (item) => _openTrackerItem(context, item),
          onLongPress: (entry) {
            showTrackerEntrySheet(
              context,
              tracker: tracker,
              item: entry.item,
              status: entry.status,
              progress: entry.progress,
              score: entry.score,
              tmdbIsTv: entry.tmdbIsTv,
              customLists: entry.customLists,
              onFind: () => _openTrackerItem(context, entry.item),
              onChanged: () => context.read<TrackerListCubit>().refresh(),
            );
          },
        );
    }
  }

  Widget _posterGrid({
    required List<MyListEntry> entries,
    required bool autofocusFirst,
    required void Function(MediaItem) onTap,
    required void Function(MyListEntry) onLongPress,
  }) {
    return GridView.builder(
      // Top inset keeps focused poster scale/outline inside the grid instead
      // of sliding up under the source-chip row (which paints beneath us).
      padding: const EdgeInsets.fromLTRB(40, 12, 40, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _crossAxisCount,
        childAspectRatio: 0.56,
        crossAxisSpacing: 18,
        mainAxisSpacing: 22,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        return TvPosterTile(
          autofocus: autofocusFirst && i == 0,
          title: entry.item.title,
          imageUrl: entry.item.cover,
          headers: entry.item.coverHeaders,
          onTap: () => onTap(entry.item),
          onLongPress: () => onLongPress(entry),
        );
      },
    );
  }

  /// Connected trackers for the current content mode, or empty when DI isn't
  /// wired (widget tests that only exercise the local list).
  static List<Tracker> _connectedTrackers() {
    if (!sl.isRegistered<TrackerHub>() ||
        !sl.isRegistered<ContentModeCubit>()) {
      return const [];
    }
    return sl<TrackerHub>()
        .connectedForMode(sl<ContentModeCubit>().state)
        .toList();
  }
}

/// Focusable source chips: My List + each connected tracker. Hidden when no
/// trackers are connected so the local-only layout matches the old screen.
class _SourceChips extends StatelessWidget {
  const _SourceChips({required this.tlState});

  final TrackerListState tlState;

  @override
  Widget build(BuildContext context) {
    if (!sl.isRegistered<TrackerHub>() ||
        !sl.isRegistered<ContentModeCubit>()) {
      return const SizedBox.shrink();
    }
    final hub = sl<TrackerHub>();
    return AnimatedBuilder(
      animation: Listenable.merge(hub.trackers),
      builder: (context, _) {
        final connected =
            hub.connectedForMode(sl<ContentModeCubit>().state).toList();
        if (connected.isEmpty) return const SizedBox.shrink();

        final cubit = context.read<TrackerListCubit>();
        // Same Row layout as Schedule's top tabs. Vertical padding reserves
        // space for the float focus ring; Clip.none so horizontal scroll
        // doesn't shave it. Keep bottom padding light — the grid supplies
        // the gap below so posters don't sit under this row.
        return Padding(
          padding: const EdgeInsets.fromLTRB(40, 8, 40, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                TvFocusable(
                  autofocus: true,
                  variant: TvFocusVariant.float,
                  scale: 1.0,
                  borderRadius: 20,
                  onTap: cubit.selectMyList,
                  child: _Chip(
                    label: 'My List',
                    selected: tlState.isMyList,
                  ),
                ),
                for (final t in connected) ...[
                  const SizedBox(width: 12),
                  TvFocusable(
                    variant: TvFocusVariant.float,
                    scale: 1.0,
                    borderRadius: 20,
                    onTap: () => cubit.selectTracker(t),
                    child: _Chip(
                      label: t.displayName == 'MyAnimeList'
                          ? 'MAL'
                          : t.displayName,
                      selected: tlState.tracker == t,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected});
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.18)
              : AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: Text(
          label,
          style: AppText.headline.copyWith(
            color: selected ? AppColors.accent : AppColors.textSecondary,
            fontSize: 15,
          ),
        ),
      );
}
