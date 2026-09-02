import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/zmode/metadata_provider_prefs.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/models/provider_info.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/media_item.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/playback/category_store.dart';
import '../../l10n/ui_strings.dart';
import '../../core/ui/reveal_item.dart';
import '../../core/ui/global_messenger.dart';
import '../../core/ui/anilist_custom_lists_sheet.dart';
import '../../core/prefs/list_sort.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../../core/ui/tracker_entry_sheet.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../detail/detail_screen.dart';
import 'cubit/my_list_cubit.dart';
import 'cubit/tracker_list_cubit.dart';
import 'my_list_screen_tv.dart';
import 'search_screen.dart';

/// My List — one library the user browses by source (their own saved list plus
/// each connected tracker) via a segmented control, and by status via tabs.
/// Trackers are connected/managed from the header's accounts button.
class MyListScreen extends StatelessWidget {
  const MyListScreen({super.key, this.initialTracker, this.initialKind});

  /// Open straight onto one tracker's library instead of your own list, with
  /// the account switcher hidden.
  ///
  /// This is how the Home cards reach a tracker: reusing this screen rather
  /// than writing a thinner one keeps statuses, custom lists, sort and filter
  /// working, which a purpose-built list screen would have quietly lost.
  final Tracker? initialTracker;

  /// Which kind of list to open for [initialTracker]. The hub names the kind
  /// on the row itself ("AniList → Manga"), so the screen must honour that
  /// rather than following whatever mode the app happens to be in — otherwise
  /// tapping Manga while in anime mode would land on the anime list.
  final ContentMode? initialKind;

  @override
  Widget build(BuildContext context) {
    final pinned = initialTracker;
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => MyListCubit(sl<MyListStore>(), sl<ListStatusStore>()),
        ),
        BlocProvider(
          create: (_) {
            // Pinned screens name their own kind: the hub opens a tracker
            // FOR a kind, which is not necessarily the app's current mode.
            final c = TrackerListCubit(pinnedKind: initialKind);
            if (pinned != null) c.selectTracker(pinned);
            return c;
          },
        ),
      ],
      child: _MyListView(pinnedTracker: pinned, pinnedKind: initialKind),
    );
  }
}

class _MyListView extends StatefulWidget {
  const _MyListView({this.pinnedTracker, this.pinnedKind});

  /// Non-null when this screen was opened FOR one tracker — the switcher is
  /// hidden and there is nothing to switch to.
  final Tracker? pinnedTracker;

  /// The kind a pinned tracker screen was opened for. Null falls back to the
  /// app's current mode, which is what the old Home cards relied on.
  final ContentMode? pinnedKind;

  @override
  State<_MyListView> createState() => _MyListViewState();
}

class _MyListViewState extends State<_MyListView> {
  WatchStatus? _statusFilter; // null = All

  /// Selected AniList custom list, or null. Separate from [_categoryFilter]:
  /// that one is ours and local, this one is AniList's own and lives on their
  /// servers. They can never both be active — categories only exist on My
  /// List, custom lists only on the AniList tab.
  String? _customListFilter;

  /// Selected user category, or null when a status tab is picked. The two are
  /// mutually exclusive: the tab row holds both, and only one tab is active.
  String? _categoryFilter;

  /// Null when the store isn't registered. Widget tests build this screen with
  /// a minimal DI set, and a library view is not worth an exception over an
  /// optional feature — no store simply means no categories.
  CategoryStore? get _cats =>
      sl.isRegistered<CategoryStore>() ? sl<CategoryStore>() : null;

  /// Null until the user picks one — the default then depends on which list is
  /// showing (your own keeps insertion order, a tracker leads with score), and
  /// that can change under us when the source switcher moves.
  ListSort? _sort = ListSortPrefs.sortBy;

  /// Which kind the local list is showing. Replaces the old implicit filter on
  /// the app's ContentMode, so you can see your manga list without switching
  /// the whole app into manga mode. Tracker screens ignore it — a tracker
  /// answers for one kind already.
  ContentMode _kind = sl<ContentModeCubit>().state;
  bool _sortDesc = ListSortPrefs.descending;

  ListSort _sortFor({required bool isMyList}) {
    final chosen = _sort;
    // A saved sort that this list can't do (score on your own list, which has
    // none) falls back rather than showing an empty-looking order.
    if (chosen != null && optionsFor(isMyList: isMyList).contains(chosen)) {
      return chosen;
    }
    return defaultSortFor(isMyList: isMyList);
  }

  Future<void> _openItem(
    BuildContext context,
    MediaItem item, {
    PreferredProvider? prefer,
  }) async {
    final cubit = context.read<MyListCubit>();
    await Navigator.push(context, DetailScreen.route(item, prefer: prefer));
    cubit.reload();
  }

  /// The catalogue behind a tracker, when it has one. A tracker that is only a
  /// tracker — no catalogue of its own — returns null and the app-wide choice
  /// stands.
  PreferredProvider? _providerOf(Tracker? t) => switch (t?.displayName) {
    'AniList' => PreferredProvider.anilist,
    'MyAnimeList' => PreferredProvider.mal,
    'Simkl' => PreferredProvider.simkl,
    _ => null,
  };

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
                _header(context),
                if (_searching) _searchField(context),
                if (widget.pinnedTracker == null) _kindTabs(context),
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

  /// Filters the list you are looking at by title — My List and every tracker
  /// list, in every kind. View state: it belongs to the screen, and a query
  /// should not survive leaving it.
  bool _searching = false;
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _query = '';
        _searchController.clear();
      }
    });
  }

  /// The search field, shown under the header while searching.
  Widget _searchField(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(21),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              cursorColor: AppColors.accent,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: context.l10n.search2,
                hintStyle: AppText.body,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (_query.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() {
                _query = '';
                _searchController.clear();
              }),
              child: Icon(
                Icons.clear_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ),
        ],
      ),
    ),
  );

  // ── Header: frosted capsule (no avatar) + search/filter + accounts ─────────

  Widget _header(BuildContext context) {
    final hub = sl<TrackerHub>();
    return AnimatedBuilder(
      // Rebuild when a tracker connects/disconnects.
      animation: Listenable.merge(hub.trackers),
      builder: (context, _) {
        final l10n = context.l10n;
        final pinned = widget.pinnedTracker;
        // Opened for one tracker: name it. Saying "Library / My List + 3
        // trackers" on a screen showing only AniList was just wrong.
        // Whose list this is: the account name earns its place here, where the
        // avatar did not — it says the same thing in less space and reads.
        final who = pinned?.viewerName;
        final title = pinned == null
            ? l10n.libraryLabel
            : (who == null || who.isEmpty
                  ? pinned.displayName
                  : '${pinned.displayName} · $who');
        // Names the kind on screen rather than "titles": a tracker screen is
        // opened FOR one, so being vague about it helps nobody.
        final subtitle = pinned == null
            ? l10n.yourSavedTitles
            : switch (widget.pinnedKind ?? sl<ContentModeCubit>().state) {
                ContentMode.manga => l10n.yourSavedMangaList,
                ContentMode.novel => l10n.yourSavedNovelList,
                ContentMode.anime => l10n.yourSavedAnimeList,
              };
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.10),
                  blurRadius: 40,
                  spreadRadius: -8,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.09),
                      width: 0.5,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                  child: Row(
                    children: [
                      // The account this list belongs to, round and leading —
                      // a tracker's own avatar, or yours on My List.
                      _headerAvatar(context, pinned),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // 19 overflowed the moment a handle was added
                              // next to the tracker's name.
                              style: AppText.title.copyWith(fontSize: 15.5),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              subtitle,
                              style: AppText.caption.copyWith(
                                color: AppColors.textTertiary,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _pillIcon(
                        _searching ? Icons.close_rounded : Icons.search_rounded,
                        l10n.search2,
                        _toggleSearch,
                        active: _query.isNotEmpty,
                      ),

                      const SizedBox(width: 8),
                      _pillIcon(
                        Icons.sort_rounded,
                        context.l10n.sort,
                        () => _openSortSheet(context),
                        active: _sort != null,
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Sort options for whichever list is showing. Tapping the active one flips
  /// its direction, which is how the reference apps do it and saves a second
  /// control.
  void _openSortSheet(BuildContext context) {
    final isMyList = context.read<TrackerListCubit>().state.isMyList;
    final options = optionsFor(isMyList: isMyList);
    final active = _sortFor(isMyList: isMyList);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(context.l10n.sortBy, style: AppText.title),
            ),
            for (final o in options)
              ListTile(
                title: Text(
                  listSortLabel(o),
                  style: AppText.body.copyWith(
                    color: o == active
                        ? AppColors.accent
                        : AppColors.textPrimary,
                    fontWeight: o == active ? FontWeight.w700 : null,
                  ),
                ),
                subtitle: o == active
                    ? Text(
                        listSortDirectionLabel(o, _sortDesc),
                        style: AppText.caption,
                      )
                    : null,
                trailing: o == active
                    ? Icon(
                        _sortDesc
                            ? Icons.arrow_downward_rounded
                            : Icons.arrow_upward_rounded,
                        color: AppColors.accent,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() {
                    // Same option again → flip direction; a new one starts in
                    // the direction people expect (best/newest/A-Z first).
                    if (o == active) {
                      _sortDesc = !_sortDesc;
                    } else {
                      _sort = o;
                      _sortDesc = o != ListSort.title;
                    }
                  });
                  ListSortPrefs.save(_sortFor(isMyList: isMyList), _sortDesc);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Create a list on the user's AniList account from the tab row, then
  /// refresh so the new tab appears.
  Future<void> _createAniListList(
    BuildContext context,
    AniListService service,
  ) async {
    final mode = sl<ContentModeCubit>().state;
    final made = await promptCreateAniListList(
      context,
      service,
      mode.isReading ? MediaKind.manga : MediaKind.anime,
    );
    if (made == null || !mounted) return;
    // The names are cached per tracker; creating one is the only thing that
    // changes them, so drop it before re-reading.
    final cubit = this.context.read<TrackerListCubit>();
    cubit.invalidateCustomListNames();
    await cubit.refresh();
  }

  /// Name a new category. Duplicate names are refused by the store (two tabs
  /// reading the same would be indistinguishable), so say so rather than
  /// failing silently.
  Future<void> _createCategory(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.newCategory, style: AppText.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
          decoration: InputDecoration(hintText: context.l10n.personaGym),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            child: Text(context.l10n.create),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final made = await sl<CategoryStore>().create(name);
    if (!mounted) return;
    if (made == null) {
      showGlobalSnack(
        name.trim().isEmpty
            ? context.l10n.giveItAName
            : context.l10n.youAlreadyHaveThatOne,
      );
      return;
    }
    setState(() => _categoryFilter = made.id); // land on the new tab
  }

  /// Rename or delete a category (long-press its tab). Deleting keeps every
  /// title — it only drops the label.
  Future<void> _manageCategory(BuildContext context, ListCategory c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(c.name, style: AppText.title),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.edit_outlined,
                color: AppColors.textSecondary,
              ),
              title: Text(context.l10n.rename),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: AppColors.accent,
              ),
              title: Text(
                context.l10n.deleteCategory,
                style: TextStyle(color: AppColors.accent),
              ),
              subtitle: Text(context.l10n.yourTitlesStayOnlyTheLabelGoes),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    if (action == 'delete') {
      await sl<CategoryStore>().delete(c.id);
      if (!mounted) return;
      setState(() {
        // Don't leave the tab row pointing at a category that's gone.
        if (_categoryFilter == c.id) _categoryFilter = null;
      });
      return;
    }

    final controller = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: this.context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.renameCategory, style: AppText.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            child: Text(context.l10n.rename),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final ok = await sl<CategoryStore>().rename(c.id, name);
    if (!mounted) return;
    if (!ok) {
      showGlobalSnack(context.l10n.thatNameIsTaken);
      return;
    }
    setState(() {});
  }

  Widget _pillIcon(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active ? AppColors.accentSoft : AppColors.surface2,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: AppColors.accent),
        ),
      ),
    );
  }

  // ── Accounts button (connected avatars + ＋, else "Connect") ───────────────

  /// The header's round avatar: the tracker's own picture on a pinned screen,
  /// and yours on My List. 30px — big enough to read as a face, small enough
  /// that the capsule stays one line.
  Widget _headerAvatar(BuildContext context, Tracker? pinned) {
    final url = pinned != null
        ? pinned.viewerAvatar
        : (sl.isRegistered<AuthCubit>()
              ? sl<AuthCubit>().state.avatarUrl
              : null);
    final letter = pinned?.displayName.isNotEmpty == true
        ? pinned!.displayName[0]
        : 'Z';
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surface2,
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: ClipOval(
        child: (url != null && url.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: url,
                width: 30,
                height: 30,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _miniLetter(letter),
              )
            : _miniLetter(letter),
      ),
    );
  }

  Widget _miniLetter(String letter) => Container(
    width: 20,
    height: 20,
    color: AppColors.accent,
    alignment: Alignment.center,
    child: Text(
      letter,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w800,
        fontSize: 10,
      ),
    ),
  );

  Widget _kindTabs(BuildContext context) {
    const kinds = ContentMode.values;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: LayoutBuilder(
        builder: (context, c) {
          final segW = (c.maxWidth - 8) / kinds.length;
          return Container(
            height: 46,
            padding: const EdgeInsets.all(4),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(23),
            ),
            child: Stack(
              children: [
                AnimatedAlign(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment(
                    kinds.length == 1
                        ? 0
                        : -1 + 2 * (kinds.indexOf(_kind) / (kinds.length - 1)),
                    0,
                  ),
                  child: Container(
                    width: segW,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(19),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final k in kinds)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _kind = k),
                          child: Center(
                            child: Text(
                              contentModeLabel(context.l10n, k),
                              style: AppText.body.copyWith(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: _kind == k
                                    ? Colors.white
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Filter sheet (type) ────────────────────────────────────────────────────

  // ── My List body ───────────────────────────────────────────────────────────

  Widget _myListBody(BuildContext context) {
    return BlocBuilder<MyListCubit, List<MyListEntry>>(
      builder: (context, entries) {
        if (entries.isEmpty) return _empty(context);
        return _grid(
          context,
          entries,
          onTap: (item) => _openItem(context, item),
          onMore: (entry) => showListStatusSheet(context, item: entry.item),
        );
      },
    );
  }

  // ── Tracker body (refresh + load/empty/error) ─────────────────────────────

  Widget _trackerBody(BuildContext context, TrackerListState tlState) {
    final Widget content;
    switch (tlState.status) {
      case TrackerListStatus.loading:
        content = Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        );
      case TrackerListStatus.error:
        content = EmptyState(
          icon: Icons.cloud_off_rounded,
          message: context.l10n.couldnTLoadPullToRefresh,
        );
      case TrackerListStatus.idle:
      case TrackerListStatus.ready:
        content = tlState.entries.isEmpty
            ? EmptyState(
                icon: Icons.bookmark_outline,
                message: context.l10n.noTitlesInThisList,
              )
            : _grid(
                context,
                tlState.entries,
                onTap: (item) => _openTrackerItem(context, item),
                onMore: (entry) => showTrackerEntrySheet(
                  context,
                  tracker: tlState.tracker!,
                  item: entry.item,
                  status: entry.status,
                  progress: entry.progress,
                  score: entry.score,
                  tmdbIsTv: entry.tmdbIsTv,
                  customLists: entry.customLists,
                  onFind: () => _openTrackerItem(context, entry.item),
                  onChanged: () => context.read<TrackerListCubit>().refresh(),
                ),
              );
    }

    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () => context.read<TrackerListCubit>().refresh(),
      child:
          tlState.status == TrackerListStatus.ready &&
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

  // ── Shared grid: status tabs (with counts) + poster grid ──────────────────

  Widget _grid(
    BuildContext context,
    List<MyListEntry> entries, {
    required void Function(MediaItem) onTap,
    void Function(MyListEntry)? onMore,
  }) {
    final cellW = _cellW(context);
    // Fixed tab order (All is prepended in _statusTabs): Watching first, then
    // Plan to Watch, Completed, Paused, Dropped — regardless of enum order.
    const tabOrder = [
      WatchStatus.watching,
      WatchStatus.planning,
      WatchStatus.completed,
      WatchStatus.paused,
      WatchStatus.dropped,
    ];
    // Reading modes (manga/novel) see only their own items; anime mode's
    // matchesProvider covers BOTH anime + movie types, so this is a no-op
    // there — today's anime My List is unaffected.
    //
    // Narrow by mode FIRST: the status tabs' counts and which tabs even appear
    // are both derived from this, so counting raw `entries` showed anime totals
    // (and anime-only status tabs) while in manga/novel mode.
    // The kind tab decides, not the app's current mode — the point of the
    // tabs is seeing all three without leaving the mode you're browsing in.
    // A tracker screen has no tabs and keeps following the app mode.
    final mode = widget.pinnedTracker == null
        ? _kind
        : (widget.pinnedKind ?? sl<ContentModeCubit>().state);
    final modeEntries = entries
        .where((e) => mode.matchesProvider(e.item.type))
        .toList();

    final presentStatuses = tabOrder
        .where((s) => modeEntries.any((e) => e.status == s))
        .toList();

    // Which list is on screen. Gates the category tabs and their filter, and
    // picks the sort defaults below — the tracker lists share this widget.
    final trackerState = context.read<TrackerListCubit>().state;
    final isMyList = trackerState.isMyList;

    // The account's own list names first — a list created but not yet filled
    // still deserves a tab. Anything an entry claims to be in is unioned on
    // top, so a stale name-fetch can't hide a tab that clearly has titles.
    final customLists = <String>[...trackerState.customListNames];
    for (final e in modeEntries) {
      for (final name in e.customLists) {
        if (!customLists.contains(name)) customLists.add(name);
      }
    }
    customLists.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final filtered = modeEntries.where((e) {
      if (_customListFilter != null &&
          !e.customLists.contains(_customListFilter)) {
        return false;
      }
      final cats = _cats;
      if (isMyList &&
          _categoryFilter != null &&
          (cats == null || !cats.isIn(e.item, _categoryFilter!))) {
        return false;
      }
      if (_statusFilter != null && e.status != _statusFilter) return false;
      if (_query.isNotEmpty) {
        // English titles count too: plenty of entries are filed under a romaji
        // name nobody would think to type.
        final q = _query.toLowerCase();
        final t = e.item.title.toLowerCase();
        final en = e.item.englishTitle?.toLowerCase() ?? '';
        if (!t.contains(q) && !en.contains(q)) return false;
      }
      return true;
    }).toList();

    // Display order only. `filtered` is already a throwaway copy and
    // sortLibrary returns another — the saved list in Hive is never touched,
    // so no sort can reorder or lose what's stored.
    final shown = sortLibrary(
      filtered,
      _sortFor(isMyList: isMyList),
      _sortDesc,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statusTabs(
          modeEntries,
          presentStatuses,
          isMyList: isMyList,
          customLists: customLists,
          anilist: trackerState.tracker is AniListService
              ? trackerState.tracker as AniListService
              : null,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.filter_list_off_rounded,
                  message: myListFilteredEmptyMessage(context.l10n, mode),
                )
              : GridView.builder(
                  key: ValueKey(
                    '${_statusFilter?.name}|$_categoryFilter|'
                    '$_customListFilter|${_sort?.name}|$_sortDesc',
                  ),
                  // Bottom: clear the floating dock, which overlays content
                  // (extendBody reserves it no space of its own).
                  padding: EdgeInsets.fromLTRB(
                    16,
                    4,
                    16,
                    MediaQuery.paddingOf(context).bottom,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(),
                  cacheExtent: 800,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: posterGridAspect(context),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final entry = shown[i];
                    return RevealItem(
                      index: i,
                      child: PosterCard(
                        title: entry.item.title,
                        imageUrl: entry.item.cover,
                        headers: entry.item.coverHeaders,
                        cellWidth: cellW,
                        onTap: () => onTap(entry.item),
                        // Long-press opens the per-card edit sheet (own list →
                        // status/remove; tracker → the tracker editor).
                        onLongPress: onMore == null
                            ? null
                            : () => onMore(entry),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Open a tracker entry.
  ///
  /// The stub carries no provider, but it does carry the id the metadata
  /// catalogue is keyed by — a MAL id from AniList/MAL, a TMDB one from Simkl
  /// — which is the same identity a `zm://` title uses. So the title can be
  /// opened directly instead of dumping you into a search for its own name.
  /// Search stays the fallback for an entry with no id to go on.
  void _openTrackerItem(BuildContext context, MediaItem stub) {
    final c = _canonicalOf(stub);
    if (c != null) {
      _openItem(
        context,
        prefer: _providerOf(widget.pinnedTracker),
        MediaItem(
          id: c.id,
          title: stub.title,
          englishTitle: stub.englishTitle,
          cover: stub.cover,
          url: ZmodeIds.showUrl(c),
          type: stub.type,
          sourceId: ZmodeIds.sourceId,
          malId: stub.malId,
          tmdbId: stub.tmdbId,
          tmdbIsTv: stub.tmdbIsTv,
          // Saved from here, it stays this tracker's title.
          savedFrom: widget.pinnedTracker?.displayName,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialQuery: stub.title),
      ),
    );
  }

  /// The metadata identity of a tracker stub, or null when it has none.
  ZCanonical? _canonicalOf(MediaItem stub) {
    final mal = stub.malId;
    if (mal != null) {
      return ZCanonical(switch (stub.type) {
        ProviderType.manga => ZKind.manga,
        ProviderType.novel => ZKind.novel,
        _ => ZKind.anime,
      }, 'mal:$mal');
    }
    final tmdb = stub.tmdbId;
    if (tmdb != null) {
      return ZCanonical(stub.tmdbIsTv ? ZKind.tv : ZKind.movie, 'tmdb:$tmdb');
    }
    return null;
  }

  /// How many of [entries] — already narrowed to the kind on screen — are in
  /// [c].
  int _categoryCount(List<MyListEntry> entries, ListCategory c) {
    final cats = _cats;
    if (cats == null) return 0;
    return entries.where((e) => cats.isIn(e.item, c.id)).length;
  }

  /// Whether [c] earns a tab for the kind currently on screen.
  ///
  /// Kept if it holds something of this kind, if you are looking at it right
  /// now, or if it is empty everywhere — that last case is what stops a
  /// category vanishing the instant you create it, before anything is in it.
  bool Function(ListCategory) _categoryFitsKind(List<MyListEntry> entries) {
    final cats = _cats;
    return (c) {
      if (cats == null) return false;
      if (_categoryFilter == c.id) return true;
      if (_categoryCount(entries, c) > 0) return true;
      return cats.countIn(c.id) == 0;
    };
  }

  // ── Status tabs (counts baked into the labels) ─────────────────────────────

  /// [isMyList] gates the category tabs and the + button. The row is shared
  /// with the tracker lists, and categories are ours alone — AniList and MAL
  /// have no idea they exist, so offering them there is meaningless.
  Widget _statusTabs(
    List<MyListEntry> entries,
    List<WatchStatus> present, {
    required bool isMyList,
    List<String> customLists = const [],
    AniListService? anilist,
  }) {
    int countOf(WatchStatus? s) =>
        s == null ? entries.length : entries.where((e) => e.status == s).length;

    Widget tab(String label, bool active, int count, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 22),
          padding: const EdgeInsets.only(top: 8, bottom: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? AppColors.accent : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppText.body.copyWith(
                  color: active ? AppColors.accent : AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: AppText.caption.copyWith(
                  color: active ? AppColors.accent : AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 16),
          children: [
            tab(
              context.l10n.all,
              _statusFilter == null &&
                  _categoryFilter == null &&
                  _customListFilter == null,
              countOf(null),
              () => setState(() {
                _statusFilter = null;
                _categoryFilter = null;
                _customListFilter = null;
              }),
            ),
            for (final s in present)
              tab(
                shortLabelFor(
                  s,
                  reading: sl<ContentModeCubit>().state.isReading,
                ),
                _statusFilter == s && _categoryFilter == null,
                countOf(s),
                () => setState(() {
                  _statusFilter = s;
                  _categoryFilter = null;
                  _customListFilter = null;
                }),
              ),
            // User-made categories come after the statuses, in their own
            // order. Long-press one to rename, delete or reorder it.
            //
            // Only the ones that mean something for the kind on screen: a
            // category is not tied to a kind, so one made under Streaming used
            // to appear under Manga and Novel as an empty tab. Counted against
            // THIS kind's entries too, for the same reason.
            for (final c
                in isMyList
                    ? (_cats?.all() ?? const <ListCategory>[])
                          .where(_categoryFitsKind(entries))
                          .toList()
                    : const <ListCategory>[])
              GestureDetector(
                onLongPress: () => _manageCategory(context, c),
                child: tab(
                  c.name,
                  _categoryFilter == c.id,
                  _categoryCount(entries, c),
                  () => setState(() {
                    _categoryFilter = c.id;
                    // A category is its own view; a status tab would fight it.
                    _statusFilter = null;
                    _customListFilter = null;
                  }),
                ),
              ),
            // AniList's own custom lists. Only ever non-empty on that tab —
            // MAL and Simkl have no such concept, and My List uses categories
            // instead.
            for (final name in customLists)
              tab(
                name,
                _customListFilter == name,
                entries.where((e) => e.customLists.contains(name)).length,
                () => setState(() {
                  _customListFilter = name;
                  _statusFilter = null;
                }),
              ),
            // The AniList tab gets its own +, creating a list on the account
            // rather than a local category. Same gesture, different home.
            if (!isMyList && anilist != null)
              GestureDetector(
                onTap: () => _createAniListList(context, anilist),
                child: Container(
                  margin: const EdgeInsets.only(right: 22),
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Icon(
                    Icons.add_rounded,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            // Last, so adding one never shifts the tabs already there.
            if (isMyList && _cats != null)
              GestureDetector(
                onTap: () => _createCategory(context),
                child: Container(
                  margin: const EdgeInsets.only(right: 22),
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Icon(
                    Icons.add_rounded,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Empty / sign-in ────────────────────────────────────────────────────────

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
                context.l10n.signInToBuildYourList,
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 180,
                child: PrimaryButton(
                  label: context.l10n.signIn,
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
    return EmptyState(
      icon: Icons.bookmark_outline,
      message: myListEmptyMessage(context.l10n, sl<ContentModeCubit>().state),
    );
  }
}

/// EmptyState message for My List's per-status/type filter turning up
/// nothing (the mode filter itself is applied before this — see [_grid]).
/// Anime mode's wording is unchanged; a reading mode names its own content
/// type instead of the generic "Nothing".
String myListFilteredEmptyMessage(AppLocalizations l10n, ContentMode mode) =>
    switch (mode) {
      ContentMode.anime => l10n.nothingHereInThisFilter,
      ContentMode.manga => l10n.noMangaHereInThisFilter,
      ContentMode.novel => l10n.noNovelsHereInThisFilter,
    };

/// EmptyState message for a genuinely empty My List (nothing saved yet, of
/// ANY type). Anime mode's wording is unchanged.
String myListEmptyMessage(AppLocalizations l10n, ContentMode mode) =>
    switch (mode) {
      ContentMode.anime => l10n.titlesYouAddAppearHere,
      ContentMode.manga => l10n.mangaYouAddAppearHere,
      ContentMode.novel => l10n.novelsYouAddAppearHere,
    };
