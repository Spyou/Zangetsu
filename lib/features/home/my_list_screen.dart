import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/models/media_item.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/playback/category_store.dart';
import '../../core/ui/global_messenger.dart';
import '../../core/ui/anilist_custom_lists_sheet.dart';
import '../../core/prefs/list_sort.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
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
import '../settings/tracker_settings_screen.dart';
import 'cubit/my_list_cubit.dart';
import 'cubit/tracker_list_cubit.dart';
import 'my_list_screen_tv.dart';
import 'search_screen.dart';

/// My List — one library the user browses by source (their own saved list plus
/// each connected tracker) via a segmented control, and by status via tabs.
/// Trackers are connected/managed from the header's accounts button.
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
  ProviderType? _typeFilter; // null = All

  /// Null until the user picks one — the default then depends on which list is
  /// showing (your own keeps insertion order, a tracker leads with score), and
  /// that can change under us when the source switcher moves.
  ListSort? _sort = ListSortPrefs.sortBy;
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

  Future<void> _openItem(BuildContext context, MediaItem item) async {
    final cubit = context.read<MyListCubit>();
    await Navigator.push(context, DetailScreen.route(item));
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
                _header(context),
                _sourceSegmented(context, tlState),
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

  // ── Header: frosted capsule (no avatar) + search/filter + accounts ─────────

  Widget _header(BuildContext context) {
    final hub = sl<TrackerHub>();
    return AnimatedBuilder(
      // Rebuild when a tracker connects/disconnects.
      animation: Listenable.merge(hub.trackers),
      builder: (context, _) {
        final n = hub
            .connectedForMode(sl<ContentModeCubit>().state)
            .length;
        final subtitle = n == 0
            ? 'Your saved titles'
            : 'My List + $n tracker${n == 1 ? '' : 's'}';
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
                        width: 0.5),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Library',
                                style: AppText.title.copyWith(fontSize: 19)),
                            const SizedBox(height: 1),
                            Text(
                              subtitle,
                              style: AppText.caption.copyWith(
                                  color: AppColors.textTertiary, fontSize: 11),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _pillIcon(
                        _typeFilter == null
                            ? Icons.tune_rounded
                            : Icons.filter_alt_rounded,
                        'Filter',
                        () => _openFilterSheet(context),
                        active: _typeFilter != null,
                      ),
                      const SizedBox(width: 8),
                      _pillIcon(
                        Icons.sort_rounded,
                        'Sort',
                        () => _openSortSheet(context),
                        active: _sort != null,
                      ),
                      const SizedBox(width: 8),
                      _accountsButton(context, hub),
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
              child: Text('Sort by', style: AppText.title),
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
        title: Text('New category', style: AppText.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Persona, Gym, …'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final made = await sl<CategoryStore>().create(name);
    if (!mounted) return;
    if (made == null) {
      showGlobalSnack(
        name.trim().isEmpty ? 'Give it a name' : 'You already have that one',
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
              leading: const Icon(Icons.edit_outlined,
                  color: AppColors.textSecondary),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded,
                  color: AppColors.accent),
              title: Text('Delete category',
                  style: TextStyle(color: AppColors.accent)),
              subtitle: const Text('Your titles stay — only the label goes'),
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
        title: Text('Rename category', style: AppText.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final ok = await sl<CategoryStore>().rename(c.id, name);
    if (!mounted) return;
    if (!ok) {
      showGlobalSnack('That name is taken');
      return;
    }
    setState(() {});
  }

  Widget _pillIcon(IconData icon, String tooltip, VoidCallback onTap,
      {bool active = false}) {
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

  Widget _accountsButton(BuildContext context, TrackerHub hub) {
    final connected =
        hub.connectedForMode(sl<ContentModeCubit>().state).toList();
    if (connected.isEmpty) {
      return GestureDetector(
        onTap: () => _openAccountsSheet(context),
        child: Container(
          height: 36,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.4), width: 1.5),
          ),
          child: Text(
            'Connect',
            style: AppText.caption.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w800,
                fontSize: 13),
          ),
        ),
      );
    }
    final show = connected.take(3).toList();
    return Tooltip(
      message: 'Manage trackers',
      child: GestureDetector(
        onTap: () => _openAccountsSheet(context),
        child: Container(
          height: 36,
          padding: const EdgeInsets.fromLTRB(7, 0, 11, 0),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24 + (show.length - 1) * 15.0,
                height: 24,
                child: Stack(
                  children: [
                    for (var i = 0; i < show.length; i++)
                      Positioned(left: i * 15.0, child: _miniAvatar(show[i])),
                  ],
                ),
              ),
              const SizedBox(width: 5),
              Icon(Icons.add_rounded, size: 18, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniAvatar(Tracker t) {
    final url = t.viewerAvatar;
    final letter = t.displayName.isNotEmpty ? t.displayName[0] : '?';
    final Widget inner = (url != null && url.isNotEmpty)
        ? CachedNetworkImage(
            imageUrl: url,
            width: 20,
            height: 20,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => _miniLetter(letter),
          )
        : _miniLetter(letter);
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.surface2, width: 2),
      ),
      child: ClipOval(child: inner),
    );
  }

  Widget _miniLetter(String letter) => Container(
    width: 20,
    height: 20,
    color: AppColors.accent,
    alignment: Alignment.center,
    child: Text(letter,
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.w800, fontSize: 10)),
  );

  Future<void> _openAccountsSheet(BuildContext context) async {
    final hub = sl<TrackerHub>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Trackers', style: AppText.headline),
              ),
            ),
            for (final t in hub.forMode(sl<ContentModeCubit>().state))
              ListTile(
                leading: SizedBox(
                  width: 34,
                  height: 34,
                  child: (t.isConnected &&
                          (t.viewerAvatar?.isNotEmpty ?? false))
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: t.viewerAvatar!,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => const Icon(
                                Icons.person_rounded,
                                color: AppColors.textTertiary),
                          ),
                        )
                      : Icon(
                          t.isConnected
                              ? Icons.check_circle_rounded
                              : Icons.add_link_rounded,
                          color: t.isConnected
                              ? AppColors.accent
                              : AppColors.textSecondary,
                        ),
                ),
                title: Text(t.displayName,
                    style: AppText.body.copyWith(color: AppColors.textPrimary)),
                subtitle: Text(
                  t.isConnected
                      ? 'Connected${t.viewerName != null ? ' · ${t.viewerName}' : ''}'
                      : 'Not connected',
                  style: AppText.caption.copyWith(
                    color: t.isConnected
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textTertiary),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TrackerSettingsScreen(tracker: t),
                    ),
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Source segmented control (sliding accent thumb) ────────────────────────

  Widget _sourceSegmented(BuildContext context, TrackerListState tlState) {
    final cubit = context.read<TrackerListCubit>();
    final hub = sl<TrackerHub>();
    return AnimatedBuilder(
      animation: Listenable.merge(hub.trackers),
      builder: (context, _) {
        final connected =
            hub.connectedForMode(sl<ContentModeCubit>().state).toList();
        final segments = <({
          String label,
          IconData? icon,
          String? avatarUrl,
          bool active,
          VoidCallback onTap,
        })>[
          (
            label: 'My List',
            icon: Icons.bookmark_rounded,
            avatarUrl: null,
            active: tlState.isMyList,
            onTap: cubit.selectMyList,
          ),
          for (final t in connected)
            (
              label: t.displayName == 'MyAnimeList' ? 'MAL' : t.displayName,
              icon: null,
              avatarUrl: t.viewerAvatar,
              active: tlState.tracker == t,
              onTap: () => cubit.selectTracker(t),
            ),
        ];
        final n = segments.length;
        final activeIndex = segments.indexWhere((s) => s.active).clamp(0, n - 1);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
          child: LayoutBuilder(
            builder: (context, c) {
              final segW = (c.maxWidth - 8) / n; // container padding = 4 each side
              return Container(
                height: 46,
                padding: const EdgeInsets.all(4),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutQuint,
                      left: activeIndex * segW,
                      top: 0,
                      bottom: 0,
                      width: segW,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (final s in segments)
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: s.onTap,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _segAvatar(
                                    icon: s.icon,
                                    avatarUrl: s.avatarUrl,
                                    label: s.label,
                                    active: s.active,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      s.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.body.copyWith(
                                        color: s.active
                                            ? Colors.white
                                            : AppColors.textSecondary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                  ),
                                ],
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
      },
    );
  }

  Widget _segAvatar({
    IconData? icon,
    String? avatarUrl,
    required String label,
    required bool active,
  }) {
    final bg = active
        ? Colors.white.withValues(alpha: 0.22)
        : Colors.white.withValues(alpha: 0.10);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatarUrl,
          width: 22,
          height: 22,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Text(
              label.isNotEmpty ? label[0] : '?',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 11),
            ),
          ),
        ),
      );
    }
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: icon != null
          ? Icon(icon, size: 14, color: Colors.white)
          : Text(
              label.isNotEmpty ? label[0] : '?',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 11),
            ),
    );
  }

  // ── Filter sheet (type) ────────────────────────────────────────────────────

  Future<void> _openFilterSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            Widget opt(String label, ProviderType? type, IconData icon) {
              final on = _typeFilter == type;
              return ListTile(
                leading: Icon(icon,
                    color: on ? AppColors.accent : AppColors.textSecondary),
                title: Text(
                  label,
                  style: AppText.body.copyWith(
                    color: on ? AppColors.accent : AppColors.textPrimary,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                trailing: on
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () {
                  setState(() => _typeFilter = type);
                  setSheet(() {});
                },
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Show', style: AppText.headline),
                  ),
                ),
                opt('All types', null, Icons.apps_rounded),
                opt('Anime', ProviderType.anime, Icons.animation_rounded),
                opt('Movies & TV', ProviderType.movie, Icons.movie_rounded),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── My List body ───────────────────────────────────────────────────────────

  Widget _myListBody(BuildContext context) {
    return BlocBuilder<MyListCubit, List<MyListEntry>>(
      builder: (context, entries) {
        if (entries.isEmpty) return _empty(context);
        return _grid(
          context,
          entries,
          onTap: (item) => _openItem(context, item),
          onMore: (entry) =>
              showListStatusSheet(context, item: entry.item),
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
                  onChanged: () =>
                      context.read<TrackerListCubit>().refresh(),
                ),
              );
    }

    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () => context.read<TrackerListCubit>().refresh(),
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
    final mode = sl<ContentModeCubit>().state;
    final modeEntries =
        entries.where((e) => mode.matchesProvider(e.item.type)).toList();

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
      if (_typeFilter != null && e.item.type != _typeFilter) return false;
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
        _statusTabs(modeEntries, presentStatuses,
            isMyList: isMyList,
            customLists: customLists,
            anilist: trackerState.tracker is AniListService
                ? trackerState.tracker as AniListService
                : null),
        const SizedBox(height: 8),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.filter_list_off_rounded,
                  message: myListFilteredEmptyMessage(mode),
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
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final entry = shown[i];
                    return PosterCard(
                      title: entry.item.title,
                      imageUrl: entry.item.cover,
                      headers: entry.item.coverHeaders,
                      cellWidth: cellW,
                      onTap: () => onTap(entry.item),
                      // Long-press opens the per-card edit sheet (own list →
                      // status/remove; tracker → the tracker editor).
                      onLongPress:
                          onMore == null ? null : () => onMore(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Open a tracker stub (no provider attached): drop into the app's global
  /// search pre-filled with the title so the user picks the source/result.
  void _openTrackerItem(BuildContext context, MediaItem stub) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialQuery: stub.title),
      ),
    );
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
                'All',
                _statusFilter == null &&
                    _categoryFilter == null &&
                    _customListFilter == null,
                countOf(null),
                () => setState(() {
                      _statusFilter = null;
                      _categoryFilter = null;
                      _customListFilter = null;
                    })),
            for (final s in present)
              tab(
                  shortLabelFor(s,
                      reading: sl<ContentModeCubit>().state.isReading),
                  _statusFilter == s && _categoryFilter == null,
                  countOf(s),
                  () => setState(() {
                        _statusFilter = s;
                        _categoryFilter = null;
                        _customListFilter = null;
                      })),
            // User-made categories come after the statuses, in their own
            // order. Long-press one to rename, delete or reorder it.
            for (final c
                in isMyList ? (_cats?.all() ?? const <ListCategory>[]) : const <ListCategory>[])
              GestureDetector(
                onLongPress: () => _manageCategory(context, c),
                child: tab(
                  c.name,
                  _categoryFilter == c.id,
                  _cats?.countIn(c.id) ?? 0,
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
                  child: Icon(Icons.add_rounded,
                      size: 20, color: AppColors.textSecondary),
                ),
              ),
            // Last, so adding one never shifts the tabs already there.
            if (isMyList && _cats != null)
              GestureDetector(
                onTap: () => _createCategory(context),
              child: Container(
                margin: const EdgeInsets.only(right: 22),
                padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Icon(Icons.add_rounded,
                      size: 20, color: AppColors.textSecondary),
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
              const Icon(Icons.bookmark_outline,
                  size: 56, color: AppColors.textTertiary),
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
    return EmptyState(
      icon: Icons.bookmark_outline,
      message: myListEmptyMessage(sl<ContentModeCubit>().state),
    );
  }
}

/// EmptyState message for My List's per-status/type filter turning up
/// nothing (the mode filter itself is applied before this — see [_grid]).
/// Anime mode's wording is unchanged; a reading mode names its own content
/// type instead of the generic "Nothing".
String myListFilteredEmptyMessage(ContentMode mode) => switch (mode) {
  ContentMode.anime => 'Nothing here in this filter',
  ContentMode.manga => 'No manga here in this filter',
  ContentMode.novel => 'No novels here in this filter',
};

/// EmptyState message for a genuinely empty My List (nothing saved yet, of
/// ANY type). Anime mode's wording is unchanged.
String myListEmptyMessage(ContentMode mode) => switch (mode) {
  ContentMode.anime => 'Titles you add appear here',
  ContentMode.manga => 'Manga you add appear here',
  ContentMode.novel => 'Novels you add appear here',
};
