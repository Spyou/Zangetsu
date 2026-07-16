import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../detail/detail_screen.dart';
import '../settings/tracker_settings_screen.dart';
import 'cubit/my_list_cubit.dart';
import 'cubit/tracker_list_cubit.dart';
import 'my_list_screen_tv.dart';

/// My List — one unified, status-organised library (the app's saved titles plus
/// AniList-imported rows), filterable by status and by type.
class MyListScreen extends StatelessWidget {
  const MyListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => MyListCubit(sl<MyListStore>(), sl<ListStatusStore>()),
        ),
        BlocProvider(create: (_) => TrackerListCubit()),
      ],
      child: const _MyListView(),
    );
  }
}

class _MyListView extends StatefulWidget {
  const _MyListView();

  @override
  State<_MyListView> createState() => _MyListViewState();
}

class _MyListViewState extends State<_MyListView> {
  WatchStatus? _statusFilter; // null = All
  ProviderType? _typeFilter; // null = All

  Future<void> _openItem(BuildContext context, MediaItem item) async {
    final cubit = context.read<MyListCubit>();
    await Navigator.push(
      context,
      DetailScreen.route(item),
    );
    cubit.reload();
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const MyListScreenTv();
    return Scaffold(
      backgroundColor: AppColors.bg,
      // bottom: false — the shell's floating dock overlays the content
      // (extendBody); a full SafeArea would clip the grid at the dock's top
      // edge, leaving a dead band on both sides of the capsule.
      body: SafeArea(
        bottom: false,
        child: BlocBuilder<TrackerListCubit, TrackerListState>(
          builder: (context, tlState) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context, tlState),
                Expanded(
                  child: tlState.isMyList
                      ? _myListBody(context)
                      : _trackerBody(context, tlState),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  double _cellW(BuildContext context) =>
      (MediaQuery.of(context).size.width - 32 - 24) / 3;

  // ── Header (title + source switcher) ──────────────────────────────────────

  Widget _header(BuildContext context, TrackerListState tlState) {
    final label = tlState.isMyList ? 'My List' : tlState.tracker!.displayName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.largeTitle),
                if (!tlState.isMyList)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Synced from ${tlState.tracker!.displayName}',
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Switch list',
            icon: const Icon(
              Icons.swap_horiz_rounded,
              color: AppColors.textSecondary,
            ),
            onPressed: () => _showSourceSwitcher(context, tlState),
          ),
        ],
      ),
    );
  }

  /// Bottom-sheet switcher: "My List" + each connected tracker (avatar + name).
  /// With no tracker connected, offers a "Connect a tracker" shortcut into the
  /// first tracker's settings screen.
  Future<void> _showSourceSwitcher(
    BuildContext context,
    TrackerListState tlState,
  ) async {
    final cubit = context.read<TrackerListCubit>();
    final hub = sl<TrackerHub>();
    final connected = hub.connected.toList();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 6),
              ListTile(
                leading: const Icon(
                  Icons.bookmark_rounded,
                  color: AppColors.textSecondary,
                ),
                title: Text('My List', style: AppText.body),
                trailing: tlState.isMyList
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  cubit.selectMyList();
                },
              ),
              for (final t in connected)
                ListTile(
                  leading: _switcherAvatar(t),
                  title: Text(t.displayName, style: AppText.body),
                  trailing: tlState.tracker == t
                      ? Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    cubit.selectTracker(t);
                  },
                ),
              if (connected.isEmpty)
                ListTile(
                  leading: Icon(
                    Icons.add_link_rounded,
                    color: AppColors.accent,
                  ),
                  title: Text('Connect a tracker', style: AppText.body),
                  subtitle: Text(
                    'Link AniList, MyAnimeList or Simkl to view your lists',
                    style: AppText.caption,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    final trackers = hub.trackers;
                    if (trackers.isEmpty) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            TrackerSettingsScreen(tracker: trackers.first),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _switcherAvatar(Tracker t) {
    final url = t.viewerAvatar;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          width: 28,
          height: 28,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _avatarFallback(),
        ),
      );
    }
    return _avatarFallback();
  }

  Widget _avatarFallback() => Container(
    width: 28,
    height: 28,
    decoration: BoxDecoration(
      color: AppColors.surface2,
      shape: BoxShape.circle,
    ),
    child: const Icon(
      Icons.account_circle_rounded,
      size: 20,
      color: AppColors.textTertiary,
    ),
  );

  // ── My List body (unchanged behaviour) ────────────────────────────────────

  Widget _myListBody(BuildContext context) {
    return BlocBuilder<MyListCubit, List<MyListEntry>>(
      builder: (context, entries) {
        if (entries.isEmpty) return _empty(context);
        return _grid(
          context,
          entries,
          onTap: (item) => _openItem(context, item),
          onLongPress: (item) => showListStatusSheet(context, item: item),
        );
      },
    );
  }

  // ── Tracker body (same grid + chips, with refresh + load/empty/error) ─────

  Widget _trackerBody(BuildContext context, TrackerListState tlState) {
    final Widget content;
    switch (tlState.status) {
      case TrackerListStatus.loading:
        content = Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        );
      case TrackerListStatus.error:
        content = const EmptyState(
          icon: Icons.cloud_off_rounded,
          message: 'Couldn’t load — pull to refresh',
        );
      case TrackerListStatus.idle:
      case TrackerListStatus.ready:
        content = tlState.entries.isEmpty
            ? const EmptyState(
                icon: Icons.bookmark_outline,
                message: 'No titles in this list',
              )
            : _grid(
                context,
                tlState.entries,
                onTap: (item) => _openTrackerItem(context, item),
                // Tracker entries are read-only (view-only) — no status sheet.
                onLongPress: null,
              );
    }

    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () => context.read<TrackerListCubit>().refresh(),
      // AlwaysScrollable so the pull gesture works even on the empty/error/
      // loading states (which aren't themselves scrollables).
      child: tlState.status == TrackerListStatus.ready &&
              tlState.entries.isNotEmpty
          ? content
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.6,
                  child: content,
                ),
              ],
            ),
    );
  }

  // ── Shared grid (same card + status/type chips for both sources) ──────────

  Widget _grid(
    BuildContext context,
    List<MyListEntry> entries, {
    required void Function(MediaItem) onTap,
    void Function(MediaItem)? onLongPress,
  }) {
    final cellW = _cellW(context);
    final hasAnime = entries.any((e) => e.item.type == ProviderType.anime);
    final hasMovies = entries.any((e) => e.item.type != ProviderType.anime);
    final presentStatuses = WatchStatus.values
        .where((s) => entries.any((e) => e.status == s))
        .toList();

    final filtered = entries.where((e) {
      if (_statusFilter != null && e.status != _statusFilter) return false;
      if (_typeFilter != null && e.item.type != _typeFilter) return false;
      return true;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statusBar(presentStatuses),
        if (hasAnime && hasMovies) _typeBar(),
        const SizedBox(height: 4),
        Expanded(
          child: filtered.isEmpty
              ? const EmptyState(
                  icon: Icons.filter_list_off_rounded,
                  message: 'Nothing here in this filter',
                )
              : GridView.builder(
                  // Bottom: clear the floating dock (its height arrives as
                  // MediaQuery bottom padding thanks to extendBody).
                  padding: EdgeInsets.fromLTRB(
                      16, 4, 16, 16 + MediaQuery.paddingOf(context).bottom),
                  physics: const AlwaysScrollableScrollPhysics(),
                  cacheExtent: 800,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 0.62,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 16,
                      ),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final entry = filtered[i];
                    return PosterCard(
                      title: entry.item.title,
                      imageUrl: entry.item.cover,
                      headers: entry.item.coverHeaders,
                      cellWidth: cellW,
                      onTap: () => onTap(entry.item),
                      // Long-press to change status / remove — the sheet updates
                      // the stores, and the cubit auto-refreshes via their
                      // revisions. Null for read-only tracker entries.
                      onLongPress: onLongPress == null
                          ? null
                          : () => onLongPress(entry.item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Open a tracker stub (no provider attached): search the app's sources by
  /// title and open the first match's detail — mirrors detail's `_openRelation`.
  /// Falls back to a snackbar when the title isn't on the user's sources.
  Future<void> _openTrackerItem(BuildContext context, MediaItem stub) async {
    _snack(context, 'Finding “${stub.title}”…');
    final repo = sl<SourceRepository>();
    // Prefer the active source, then sweep the rest until one returns a hit —
    // the active source is usually the user's chosen anime provider; if it has
    // no match (or isn't anime), the fan-out covers the installed providers.
    final ordered = <String>[
      repo.sourceId,
      for (final s in repo.loadedSources)
        if (s.id != repo.sourceId) s.id,
    ];
    try {
      for (final id in ordered) {
        List<MediaItem> results;
        try {
          results = await repo.search(stub.title, sourceId: id);
        } catch (_) {
          continue; // a broken source shouldn't stop the search
        }
        if (results.isNotEmpty) {
          if (!context.mounted) return;
          await Navigator.of(context).push(DetailScreen.route(results.first));
          return;
        }
      }
      if (context.mounted) {
        _snack(context, '“${stub.title}” isn’t on your sources');
      }
    } catch (_) {
      if (context.mounted) _snack(context, 'Couldn’t open “${stub.title}”');
    }
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: AppText.caption.copyWith(color: Colors.white),
          ),
          backgroundColor: AppColors.surface2,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // ── Filter bars ────────────────────────────────────────────────────────────

  Widget _statusBar(List<WatchStatus> present) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip('All', _statusFilter == null, () {
            setState(() => _statusFilter = null);
          }),
          for (final s in present)
            _chip(s.shortLabel, _statusFilter == s, () {
              setState(() => _statusFilter = s);
            }),
        ],
      ),
    );
  }

  Widget _typeBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip('All types', _typeFilter == null, () {
            setState(() => _typeFilter = null);
          }, small: true),
          _chip('Anime', _typeFilter == ProviderType.anime, () {
            setState(() => _typeFilter = ProviderType.anime);
          }, small: true),
          _chip('Movies', _typeFilter == ProviderType.movie, () {
            setState(() => _typeFilter = ProviderType.movie);
          }, small: true),
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap, {bool small = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: small ? 12 : 14, vertical: 7),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppText.caption.copyWith(
              color: active ? Colors.white : AppColors.textSecondary,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              fontSize: small ? 12 : 13,
            ),
          ),
        ),
      ),
    );
  }

  // ── Empty / sign-in ──────────────────────────────────────────────────────
  Widget _empty(BuildContext context) {
    final auth = context.watch<AuthCubit>().state;
    if (!auth.isLoggedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.bookmark_outline,
                size: 56,
                color: AppColors.textTertiary,
              ),
              const SizedBox(height: 16),
              Text(
                'Sign in to build your list',
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 180,
                child: PrimaryButton(
                  label: 'Sign in',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return const EmptyState(
      icon: Icons.bookmark_outline,
      message: 'Titles you add appear here',
    );
  }
}
