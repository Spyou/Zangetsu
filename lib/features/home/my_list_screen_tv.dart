import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/media_item.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/category_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/prefs/list_sort.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker_item_url.dart';
import '../../l10n/l10n.dart';
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
import 'library_filter.dart';
import 'search_screen.dart';

/// TV My List: a full-screen focusable poster grid backed by [MyListCubit]
/// (own list) and [TrackerListCubit] (AniList / MAL / Simkl when connected).
///
/// Reuses the phone's cubits unchanged. Only the interaction model changes:
/// each card is wrapped in [TvFocusable] so the D-pad navigates the grid, OK
/// opens Detail (or Search for tracker stubs), and a held OK opens the same
/// status/remove sheet as the phone long-press. A chip row switches between
/// My List and each connected tracker — same sources as the phone segmented
/// control. A second row filters by status / custom list and sorts, matching
/// the phone tabs. The rail↔content focus bridge in [RootShellTv] already
/// handles LEFT-at-edge → rail.
class MyListScreenTv extends StatefulWidget {
  const MyListScreenTv({super.key, this.initialStatus});

  /// Land on one status chip instead of All — same contract as the phone
  /// screen's [MyListScreen.initialStatus].
  final WatchStatus? initialStatus;

  /// 6 columns keeps the cards near the home-rail ~140 dp scale on a 1080p TV
  /// (matches the see-all grid; 5 rendered them oversized).
  static const int crossAxisCount = 6;

  @override
  State<MyListScreenTv> createState() => _MyListScreenTvState();
}

class _MyListScreenTvState extends State<MyListScreenTv> {
  late WatchStatus? _statusFilter = widget.initialStatus;
  String? _customListFilter;
  String? _categoryFilter;
  ListSort? _sort = ListSortPrefs.sortBy;
  bool _sortDesc = ListSortPrefs.descending;

  CategoryStore? get _cats =>
      sl.isRegistered<CategoryStore>() ? sl<CategoryStore>() : null;

  Future<void> _openOwnItem(BuildContext context, MediaItem item) async {
    final cubit = context.read<MyListCubit>();
    await Navigator.push(context, DetailScreen.route(item));
    cubit.reload();
  }

  /// TV used to send EVERY tracker entry to a search, even the ones carrying
  /// the catalogue id that opens Detail directly. Same rule as the phone now:
  /// open it if we can identify it, search only when we cannot.
  void _openTrackerItem(BuildContext context, MediaItem stub) {
    final item = playableTrackerItem(stub);
    if (item != null) {
      _openOwnItem(context, item);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialQuery: stub.title),
      ),
    );
  }

  ListSort _sortFor({required bool isMyList}) {
    final chosen = _sort;
    if (chosen != null && optionsFor(isMyList: isMyList).contains(chosen)) {
      return chosen;
    }
    return defaultSortFor(isMyList: isMyList);
  }

  void _cycleSort({required bool isMyList}) {
    final options = optionsFor(isMyList: isMyList);
    final current = _sortFor(isMyList: isMyList);
    final i = options.indexOf(current);
    final next = options[(i + 1) % options.length];
    setState(() => _sort = next);
    ListSortPrefs.save(next, _sortDesc);
  }

  void _toggleSortDir({required bool isMyList}) {
    setState(() => _sortDesc = !_sortDesc);
    ListSortPrefs.save(_sortFor(isMyList: isMyList), _sortDesc);
  }

  void _selectFilter(String id) {
    setState(() {
      _statusFilter = null;
      _customListFilter = null;
      _categoryFilter = null;
      if (id.startsWith('status:')) {
        final name = id.substring(7);
        _statusFilter = WatchStatus.values.firstWhere((s) => s.name == name);
      } else if (id.startsWith('cat:')) {
        _categoryFilter = id.substring(4);
      } else if (id.startsWith('list:')) {
        _customListFilter = id.substring(5);
      }
    });
  }

  String get _selectedFilterId {
    if (_categoryFilter != null) return 'cat:$_categoryFilter';
    if (_customListFilter != null) return 'list:$_customListFilter';
    if (_statusFilter != null) return 'status:${_statusFilter!.name}';
    return 'all';
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
                  child: Text(context.l10n.myList, style: AppText.largeTitle),
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
          return EmptyState(
            icon: Icons.bookmark_outline,
            message: context.l10n.titlesYouAddAppearHere,
          );
        }
        return _filteredGrid(
          context,
          entries: entries,
          isMyList: true,
          autofocusFirst: false,
          onTap: (item) => _openOwnItem(context, item),
          onLongPress: (entry) {
            final cubit = context.read<MyListCubit>();
            showListStatusSheet(
              context,
              item: entry.item,
              malId: entry.item.malId,
              tmdbId: entry.item.tmdbId,
              tmdbIsTv: entry.item.tmdbIsTv,
              imdbId: entry.item.imdbId,
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
        return EmptyState(
          icon: Icons.cloud_off_rounded,
          message: context.l10n.couldnTLoadTryAgainFromSettings,
        );
      case TrackerListStatus.idle:
      case TrackerListStatus.ready:
        if (tlState.entries.isEmpty) {
          return EmptyState(
            icon: Icons.bookmark_outline,
            message: context.l10n.noTitlesInThisList,
          );
        }
        final tracker = tlState.tracker!;
        return _filteredGrid(
          context,
          entries: tlState.entries,
          isMyList: false,
          customListNames: tlState.customListNames,
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

  Widget _filteredGrid(
    BuildContext context, {
    required List<MyListEntry> entries,
    required bool isMyList,
    required bool autofocusFirst,
    required void Function(MediaItem) onTap,
    required void Function(MyListEntry) onLongPress,
    List<String> customListNames = const [],
  }) {
    final statuses = presentLibraryStatuses(entries);
    final customLists = <String>[...customListNames];
    if (!isMyList) {
      for (final e in entries) {
        for (final name in e.customLists) {
          if (!customLists.contains(name)) customLists.add(name);
        }
      }
      customLists.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    final categories = isMyList
        ? (_cats?.all() ?? const <ListCategory>[])
        : const <ListCategory>[];

    final shown = sortLibrary(
      filterLibraryEntries(
        entries,
        status: (_customListFilter == null && _categoryFilter == null)
            ? _statusFilter
            : null,
        customList: _customListFilter,
        inCategory: _categoryFilter == null
            ? null
            : (e) => _cats?.isIn(e.item, _categoryFilter!) ?? false,
      ),
      _sortFor(isMyList: isMyList),
      _sortDesc,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FilterChips(
          statuses: statuses,
          customLists: isMyList ? const [] : customLists,
          categories: categories,
          selectedId: _selectedFilterId,
          sortLabel: _sortChipLabel(isMyList: isMyList),
          autofocusAll: _connectedTrackers().isEmpty,
          onSelect: _selectFilter,
          onCycleSort: () => _cycleSort(isMyList: isMyList),
          onToggleSortDir: () => _toggleSortDir(isMyList: isMyList),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.filter_list_off_rounded,
                  message: context.l10n.noTitlesInThisList,
                )
              : _posterGrid(
                  entries: shown,
                  autofocusFirst: autofocusFirst,
                  onTap: onTap,
                  onLongPress: onLongPress,
                ),
        ),
      ],
    );
  }

  String _sortChipLabel({required bool isMyList}) {
    final by = _sortFor(isMyList: isMyList);
    return '${listSortLabel(by)} · ${listSortDirectionLabel(by, _sortDesc)}';
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
        crossAxisCount: MyListScreenTv.crossAxisCount,
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
        final connected = hub
            .connectedForMode(sl<ContentModeCubit>().state)
            .toList();
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
                  onTap: () {
                    cubit.selectMyList();
                    if (sl.isRegistered<MyListStore>()) {
                      unawaited(sl<MyListStore>().pullFromCloud());
                    }
                  },
                  child: _Chip(
                    label: context.l10n.myList,
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

/// Status / custom-list / category chips plus a sort chip. One row so D-pad
/// focus stays a single left-right pass under the source chips.
class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.statuses,
    required this.customLists,
    required this.categories,
    required this.selectedId,
    required this.sortLabel,
    required this.autofocusAll,
    required this.onSelect,
    required this.onCycleSort,
    required this.onToggleSortDir,
  });

  final List<WatchStatus> statuses;
  final List<String> customLists;
  final List<ListCategory> categories;
  final String selectedId;
  final String sortLabel;
  final bool autofocusAll;
  final void Function(String id) onSelect;
  final VoidCallback onCycleSort;
  final VoidCallback onToggleSortDir;

  @override
  Widget build(BuildContext context) {
    final reading =
        sl.isRegistered<ContentModeCubit>() &&
        sl<ContentModeCubit>().state.isReading;
    final chips = <Widget>[
      TvFocusable(
        autofocus: autofocusAll,
        variant: TvFocusVariant.float,
        scale: 1.0,
        borderRadius: 20,
        onTap: () => onSelect('all'),
        child: _Chip(label: context.l10n.all, selected: selectedId == 'all'),
      ),
      for (final st in statuses) ...[
        const SizedBox(width: 12),
        TvFocusable(
          variant: TvFocusVariant.float,
          scale: 1.0,
          borderRadius: 20,
          onTap: () => onSelect('status:${st.name}'),
          child: _Chip(
            label: shortLabelFor(st, reading: reading),
            selected: selectedId == 'status:${st.name}',
          ),
        ),
      ],
      for (final c in categories) ...[
        const SizedBox(width: 12),
        TvFocusable(
          variant: TvFocusVariant.float,
          scale: 1.0,
          borderRadius: 20,
          onTap: () => onSelect('cat:${c.id}'),
          child: _Chip(label: c.name, selected: selectedId == 'cat:${c.id}'),
        ),
      ],
      for (final name in customLists) ...[
        const SizedBox(width: 12),
        TvFocusable(
          variant: TvFocusVariant.float,
          scale: 1.0,
          borderRadius: 20,
          onTap: () => onSelect('list:$name'),
          child: _Chip(label: name, selected: selectedId == 'list:$name'),
        ),
      ],
      const SizedBox(width: 20),
      TvFocusable(
        variant: TvFocusVariant.float,
        scale: 1.0,
        borderRadius: 20,
        onTap: onCycleSort,
        onLongPress: onToggleSortDir,
        child: _Chip(label: sortLabel, selected: false),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(children: chips),
      ),
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
