import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/category_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/reading/read_history.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_shell_tab_scope.dart';
import '../../core/ui/dock_visibility.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens_tv.dart';
import '../auth/reconnect.dart';
import '../downloads/downloads_screen.dart';
import '../../l10n/l10n.dart';
import '../home/cubit/home_cubit.dart';
import '../schedule/schedule_screen.dart';
import '../profiles/viewer_profiles_screen.dart';
import 'root_shell.dart';

/// Width of the TV-only navigation zone while it is focused.
const double _kNavExpanded = 224;

/// Horizontal inset for the TV navigation focus chrome.
const double _kRailHPad = 18;

/// Width of each navigation icon column.
const double _kIconSlot = 38;

/// Width of the persistent icon rail (icon slot + both horizontal insets).
const double _kNavCollapsed = _kIconSlot + _kRailHPad * 2;

/// TV-only navigation shell: a persistent icon rail over an [IndexedStack].
///
/// Rendered when [AppMode.isTv] is true (gated in [RootShell.build]). The phone
/// [RootShell] and its [NavigationBar] are completely unchanged.
///
/// The rail stays visible as a narrow icon strip; moving focus into it (LEFT
/// from content) expands it into a labelled drawer, and returning focus to
/// content collapses it back to icons. Pages reuse [buildShellPages] from
/// [RootShell] (one source of truth); all cubits are GetIt singletons so
/// nothing is re-instantiated.
class RootShellTv extends StatefulWidget {
  const RootShellTv({super.key});

  @override
  State<RootShellTv> createState() => _RootShellTvState();
}

/// One entry in the TV nav.
class _RailItem {
  const _RailItem({required this.label, required this.iconAsset});
  final String label;
  final String iconAsset;
}

enum _AvatarAction { changeProfile, logOut }

const int _kRailItemCount = 6;
const int _kMyListRailItem = 2;

List<_RailItem> _railItems(BuildContext context) {
  final l = context.l10n;
  return [
    _RailItem(label: l.home, iconAsset: 'house'),
    _RailItem(label: l.search, iconAsset: 'search'),
    _RailItem(label: l.myList, iconAsset: 'bookmark'),
    _RailItem(label: l.downloads, iconAsset: 'download'),
    _RailItem(label: l.schedule, iconAsset: 'calendar-days'),
    _RailItem(label: l.settingsTitle, iconAsset: 'settings'),
  ];
}

/// App-root override of [DirectionalFocusAction] so the TV shell can open/close
/// the nav rail on LEFT/RIGHT from wherever focus happens to be. Unlike the
/// per-scope key handlers, an [Actions] entry near the shell root is always an
/// ancestor of the focused node, so it still fires if focus ever lands outside
/// the content/rail scopes. Anything it doesn't special-case falls through to
/// the default directional move via [super].
class _TvRailDirectionalAction extends DirectionalFocusAction {
  _TvRailDirectionalAction(this._state);
  final _RootShellTvState _state;

  @override
  void invoke(DirectionalFocusIntent intent) {
    if (_state.mounted && _state._railDirectional(intent.direction)) return;
    super.invoke(intent);
  }
}

class _RootShellTvState extends State<RootShellTv> with WidgetsBindingObserver {
  static const int _searchRailItem = 1;

  int _index = 0;

  /// tvOS: only mount tabs the user has opened — cloud-restore boots build a
  /// heavy shell; building every [IndexedStack] child on the first frame can
  /// delay the splash overlay from clearing.
  final Set<int> _mountedPages = {0};
  bool _navOpen = false; // visible ⇔ focus is in the rail zone
  List<Widget>? _cachedPages;
  String? _cachedPageContext;
  DateTime? _lastBackPress;

  final ValueNotifier<int> _searchFocusSignal = ValueNotifier<int>(0);

  // ── D-pad bridge: rail ↔ content (unchanged from the original) ────────────
  final FocusScopeNode _railScope = FocusScopeNode(debugLabel: 'tv-rail-scope');
  final FocusScopeNode _contentScope = FocusScopeNode(
    debugLabel: 'tv-content-scope',
  );

  // One focus node per nav item so entering the rail can land straight on the
  // CURRENT page's item (so you always see where you are).
  final List<FocusNode> _navNodes = List.generate(
    _kRailItemCount,
    (_) => FocusNode(),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (sl.isRegistered<ViewerProfileStore>()) {
      sl<ViewerProfileStore>().active.addListener(_onProfileChanged);
      sl<ViewerProfileStore>().contextRevision.addListener(
        _onProfileContextChanged,
      );
    }
    _recoverFocusIfNeeded();
  }

  void _onProfileChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onProfileContextChanged() {
    if (!mounted) return;
    final profileId = sl<ViewerProfileStore>().activeId;
    if (sl.isRegistered<HomeCubit>()) {
      unawaited(sl<HomeCubit>().reloadAfterProfileChange());
    }
    unawaited(_syncProfile(profileId));
  }

  Future<void> _syncProfile(String profileId) async {
    if (!sl.isRegistered<MyListStore>() ||
        !sl.isRegistered<WatchHistory>() ||
        !sl.isRegistered<ReadHistory>() ||
        !sl.isRegistered<CategoryStore>()) {
      return;
    }
    try {
      await Future.wait([
        sl<MyListStore>().seedCloudIfNeeded(),
        sl<WatchHistory>().seedCloudIfNeeded(),
        sl<ReadHistory>().seedCloudIfNeeded(),
      ]).timeout(const Duration(seconds: 8));
      if (!mounted || sl<ViewerProfileStore>().activeId != profileId) return;
      await Future.wait([
        sl<MyListStore>().pullFromCloud(forProfileId: profileId),
        sl<WatchHistory>().pullFromCloud(forProfileId: profileId),
        sl<ReadHistory>().pullFromCloud(forProfileId: profileId),
        sl<CategoryStore>().pullFromCloud(),
      ]).timeout(const Duration(seconds: 8));
      if (mounted && sl<ViewerProfileStore>().activeId == profileId) {
        sl<HomeCubit>().relayout();
      }
    } catch (_) {
      // Keep the already-available local profile usable when cloud sync fails.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The default TV player (nativeTvPlayer) is a SEPARATE Android Activity, so
    // closing it resumes us. Focus can come back stuck in the rail or on a stray
    // node — the shell's custom LEFT-open / RIGHT-exit key bridges are dead until
    // a restart. Pull focus back to content on resume to recover without one.
    if (state != AppLifecycleState.resumed) return;
    _resumeReseed(0);
  }

  /// After the native player Activity resumes, the shell's custom key bridges go
  /// dead (plain up/down traversal still works, but LEFT-open / RIGHT-exit
  /// don't) — focus comes back on a node that isn't wired to the live scope
  /// handlers. Different TVs park it differently: standard Android TV (Xiaomi)
  /// leaves it in the rail; Fire TV leaves it on a STALE content node — that
  /// reports `_contentScope.hasFocus == true`, yet the node is no longer in the
  /// live tree so its key chain (incl. _onContentKey) is dead. So "content has
  /// focus" is NOT proof the bridge works.
  ///
  /// The reliable test is whether the focused node is an actual LIVE content
  /// leaf (present in the current traversal set). If it is, its chain includes
  /// _onContentKey and we leave it alone (no cursor jump). Otherwise — rail,
  /// stray node, or stale content node — request a fresh content leaf, which
  /// rebinds a live _onContentKey (from which LEFT opens the rail again) and
  /// closes any stuck-open drawer. Retries a few frames while Home rebuilds
  /// after playback (its leaves may not exist yet).
  void _resumeReseed(int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || attempt > 8) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final leaves = _contentScope.traversalDescendants
          .where((n) => n.canRequestFocus)
          .toList();
      if (leaves.isEmpty) {
        _resumeReseed(attempt + 1); // content still rebuilding — try next frame
        return;
      }
      // Healthy iff focus is on a LIVE content leaf — leave it (avoids a jump).
      final pf = FocusManager.instance.primaryFocus;
      if (pf != null && leaves.contains(pf)) return;
      leaves.first.requestFocus();
    });
  }

  /// Re-seed a sane focus target when the shell is (re)shown and nothing real
  /// holds focus. Guards the empty/no-provider Home at startup (a bare scope
  /// node renders no cursor) AND recovers after returning from the native
  /// player. Only acts when this shell is the visible route, so it never steals
  /// focus from a pushed Detail screen or dialog.
  void _recoverFocusIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary is FocusScopeNode) {
        _railScope.traversalDescendants
            .where((n) => n.canRequestFocus)
            .firstOrNull
            ?.requestFocus();
      }
    });
  }

  KeyEventResult _onRailKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _focusContentFromRail();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Move focus from the rail back into the content — the last-focused item if
  /// it's still around, else the first focusable one.
  void _focusContentFromRail() {
    final lastFocused = _contentScope.focusedChild;
    if (lastFocused != null && lastFocused.canRequestFocus) {
      lastFocused.requestFocus();
    } else {
      _contentScope.traversalDescendants
          .where((n) => n.canRequestFocus)
          .firstOrNull
          ?.requestFocus();
    }
  }

  /// Move focus into the rail so it appears (its onFocusChange drives
  /// [_navOpen]). A single requestFocus can silently no-op after the shell was
  /// covered by the player/detail route and revealed — the rail scope comes back
  /// stale — so if focus didn't cross in, retry next frame by seeding from the
  /// rail's focusable descendants (the same recovery [_recoverFocusIfNeeded]
  /// uses), which reliably takes. The normal case hits the fast path and the
  /// post-frame check early-returns, so behaviour is unchanged when it works.
  void _openRail() {
    final node = _navNodes[_index];
    if (node.canRequestFocus) {
      node.requestFocus();
    } else {
      _railScope.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _railScope.hasFocus) return;
      _railScope.traversalDescendants
          .where((n) => n.canRequestFocus)
          .firstOrNull
          ?.requestFocus();
    });
  }

  // NB: the rail bridge (this + [_onRailKey] + [_railDirectional]) is
  // deliberately NOT gated on MediaQuery.accessibleNavigation anymore. Fire TV
  // reports that flag true after returning from the native player Activity even
  // with no screen reader running, and the old gate turned the LEFT-opens-rail
  // gesture completely off in that state — so the drawer became impossible to
  // open until an app restart. Opening the rail on a left-edge press is fine to
  // do whether or not a screen reader is on.
  KeyEventResult _onContentKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _openRailOnLeft();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// LEFT from content: step to the poster on the left if there really is one in
  /// the SAME row, otherwise open the rail. Sturdier than the old
  /// `focusInDirection(left)` check — every Home item (hero buttons + all rail
  /// cards) lives in ONE flat scope, so that call can jump to another row's
  /// first card (returning true) and skip opening the rail, e.g. from the hero
  /// banner. Deciding "am I at my row's left edge?" by geometry makes the menu
  /// open reliably wherever focus lands.
  void _openRailOnLeft() {
    final pf = FocusManager.instance.primaryFocus;
    final r = pf?.rect;
    if (r == null) {
      _openRail();
      return;
    }
    var hasLeftInRow = false;
    for (final n in _contentScope.traversalDescendants) {
      if (identical(n, pf) || !n.canRequestFocus) continue;
      final nr = n.rect;
      final sameRow = (nr.center.dy - r.center.dy).abs() <= r.height * 0.6;
      if (sameRow && nr.left < r.left - 1) {
        hasLeftInRow = true;
        break;
      }
    }
    if (hasLeftInRow) {
      pf?.focusInDirection(TraversalDirection.left);
    } else {
      _openRail();
    }
  }

  /// The rail open/close gesture expressed against Flutter's directional-focus
  /// intent, so it can also run from an app-root [Actions] override. A fallback:
  /// that override stays in the key chain even if focus ever lands OUTSIDE the
  /// content/rail scopes (where [_onContentKey]/[_onRailKey] would be bypassed).
  /// On a healthy TV the scope handlers consume the key first, so this never
  /// runs there.
  ///
  /// Returns true when it handled the direction (rail opened/closed); false to
  /// let the default directional move run.
  bool _railDirectional(TraversalDirection dir) {
    if (dir == TraversalDirection.left && !_railScope.hasFocus) {
      _openRailOnLeft();
      return true;
    }
    if (dir == TraversalDirection.right && _railScope.hasFocus) {
      _focusContentFromRail();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (sl.isRegistered<ViewerProfileStore>()) {
      sl<ViewerProfileStore>().active.removeListener(_onProfileChanged);
      sl<ViewerProfileStore>().contextRevision.removeListener(
        _onProfileContextChanged,
      );
    }
    _searchFocusSignal.dispose();
    _railScope.dispose();
    _contentScope.dispose();
    for (final n in _navNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _onItemSelected(int i) {
    setState(() {
      _index = i;
      if (isAppleTv) _mountedPages.add(i);
    });
    if (i == _kMyListRailItem && sl.isRegistered<MyListStore>()) {
      unawaited(sl<MyListStore>().pullFromCloud());
    }
    if (i == _searchRailItem) _searchFocusSignal.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _contentScope.traversalDescendants
          .where((n) => n.canRequestFocus)
          .firstOrNull
          ?.requestFocus();
    });
  }

  /// tvOS: load provider JS before [HomeCubit] hits QuickJS — a cloud-restore
  /// pick (e.g. AniKoto) can be enabled in the registry but not yet evaluated.
  Future<void> _reloadHomeForSource(String sourceId) async {
    debugPrint('[tv-shell] _reloadHomeForSource · sourceId=$sourceId');
    if (isAppleTv) {
      final ok = await sl<ProviderRegistry>()
          .ensureRuntimeLoaded(sourceId)
          .catchError((_) => false);
      if (!ok || sl<ProviderManager>().get(sourceId) == null) {
        debugPrint(
          '[tv-shell] _reloadHomeForSource · '
          'ensureRuntimeLoaded failed or provider not found',
        );
        return;
      }
    }
    debugPrint('[tv-shell] _reloadHomeForSource → loading HomeCubit');
    sl<HomeCubit>().load(reset: true);
  }

  void _handlePopInvoked(bool didPop, dynamic result) {
    if (didPop) return;
    // Settings (section drill-down / nested leaf) owns this Back — same route
    // as this PopScope, so Flutter fires us too. Stand down like the phone shell.
    if (shellBackIntercepted.value) return;
    if (_index != 0) {
      setState(() => _index = 0);
      return;
    }
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!).inSeconds < 2) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(context.l10n.pressBackAgainToExitTv),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  List<Widget> get _pages {
    final shared = buildShellPages(
      _searchFocusSignal,
      homeIsActive: _index == 0,
    );
    final pages = <Widget>[
      ...shared.sublist(0, 3), // Home, Search, My List
      const DownloadsScreen(),
      const ScheduleScreen(),
      shared[3], // Settings; the phone Profile tab uses the same destination.
    ];
    final profileId = sl.isRegistered<ViewerProfileStore>()
        ? sl<ViewerProfileStore>().dataProfileId
        : 'default';
    return [
      for (var i = 0; i < pages.length; i++)
        KeyedSubtree(key: ValueKey('$profileId:$i'), child: pages[i]),
    ];
  }

  Widget _pageAt(int index, List<Widget> pages) {
    if (!isAppleTv || _mountedPages.contains(index)) return pages[index];
    return const SizedBox.shrink();
  }

  // ── Drawer pieces ─────────────────────────────────────────────────────────

  Widget _navItem(int i, _RailItem item) {
    final selected = _index == i;
    return TvFocusable(
      focusNode: _navNodes[i],
      variant: TvFocusVariant.none,
      semanticLabel: item.label,
      onTap: () => _onItemSelected(i),
      builder: (focused) => AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        height: 58,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: focused ? Colors.white : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: AnimatedScale(
          scale: focused ? 1.06 : 1,
          alignment: Alignment.centerLeft,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: Row(
            children: [
              SizedBox(
                width: _kNavCollapsed - 3,
                child: Image.asset(
                  'assets/icons/lucide/${item.iconAsset}.png',
                  excludeFromSemantics: true,
                  color: focused || selected ? Colors.white : Colors.white54,
                  width: 21,
                  height: 21,
                  filterQuality: FilterQuality.high,
                ),
              ),
              Expanded(
                child: _dockLabel(
                  ExcludeSemantics(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        color: focused ? Colors.white : Colors.white70,
                        fontSize: 16,
                        fontWeight: focused ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dockLabel(Widget child) => AnimatedSlide(
    offset: _navOpen ? Offset.zero : const Offset(-0.08, 0),
    duration: _dockDuration,
    curve: Curves.easeOutCubic,
    child: AnimatedOpacity(
      opacity: _navOpen ? 1 : 0,
      duration: _dockDuration,
      curve: Curves.easeOutCubic,
      child: child,
    ),
  );

  Duration get _dockDuration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 360);
  Future<void> _confirmProfileSwitch() async {
    final auth = context.read<AuthCubit>();
    final action = await showDialog<_AvatarAction>(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        return AlertDialog(
          title: Text(l10n.changeProfile),
          content: Text(l10n.chooseWhoIsWatching),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_AvatarAction.logOut),
              child: Text(l10n.logOut),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_AvatarAction.changeProfile),
              child: Text(l10n.change),
            ),
          ],
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == _AvatarAction.logOut) {
      // Back the library up first (if we have a live session) so the
      // logout-time clearLocal can't lose an un-synced library.
      await backupLibraryIfPossible();
      await auth.logout();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ViewerProfilesScreen(selectionOnly: true),
      ),
    );
    if (mounted) _openRail();
  }

  /// Profile shortcut at the top of the dock. Always
  /// visible: signed in → avatar + name (OK opens the profile switch confirmation); signed
  /// out → a placeholder + "Sign in" (OK opens the TV login screen).
  Widget _avatarBlock() => BlocBuilder<AuthCubit, AuthState>(
    builder: (context, auth) {
      final profile = sl.isRegistered<ViewerProfileStore>()
          ? sl<ViewerProfileStore>().activeProfile
          : null;
      final name = auth.isLoggedIn
          ? (profile?.name ?? auth.displayName)
          : context.l10n.signIn;
      final avatar = profile?.photoUrl ?? auth.avatarUrl;
      return TvFocusable(
        key: const ValueKey('tv-nav-avatar'),
        variant: TvFocusVariant.none,
        semanticLabel: name,
        onTap: () {
          if (auth.isLoggedIn) {
            _confirmProfileSwitch();
          } else {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LoginScreenTv()),
            );
          }
        },
        builder: (focused) => SizedBox(
          height: 42,
          child: Row(
            children: [
              Container(
                width: _kIconSlot,
                height: _kIconSlot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: focused ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                ),
                padding: const EdgeInsets.all(2),
                child: CircleAvatar(
                  backgroundColor: AppColors.surface2,
                  backgroundImage: avatar?.isNotEmpty == true
                      ? NetworkImage(avatar!)
                      : null,
                  child: avatar?.isNotEmpty == true
                      ? null
                      : const Icon(
                          Icons.person_outline,
                          size: 20,
                          color: Colors.white,
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _dockLabel(
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  /// TV navigation stays laid out while hidden so LEFT can restore focus.
  Widget _railColumn() => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        child: Column(
          key: const ValueKey('tv-nav-group'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _kRailHPad),
              child: _avatarBlock(),
            ),
            const SizedBox(height: 18),
            for (var i = 0; i < _kRailItemCount; i++)
              _navItem(i, _railItems(context)[i]),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final profiles = sl.isRegistered<ViewerProfileStore>()
        ? sl<ViewerProfileStore>()
        : null;
    final pageContext =
        '$_index:${profiles?.dataProfileId}:${profiles?.contextRevision.value}';
    // Opening the dock must not rebuild every Home/Search/Settings page.
    if (_cachedPages == null || _cachedPageContext != pageContext) {
      _cachedPages = _pages;
      _cachedPageContext = pageContext;
    }
    final pages = _cachedPages!;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handlePopInvoked,
      child: BlocListener<ActiveSourceCubit, String>(
        listenWhen: (prev, curr) => prev != curr,
        listener: (context, sourceId) {
          if (sl<AppMode>().isTv && !tvosProvidersReady) return;
          unawaited(_reloadHomeForSource(sourceId));
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            DirectionalFocusIntent: _TvRailDirectionalAction(this),
          },
          child: Scaffold(
            backgroundColor: AppColors.bg,
            body: Stack(
              children: [
                // ── Page area (fills the width; inset left by the collapsed rail
                //    so content is never hidden behind it; the expanded drawer
                //    overlays this inset — Apple-TV style). ────────────────────
                Positioned.fill(
                  child: RepaintBoundary(
                    child: ImageFiltered(
                      enabled: _navOpen,
                      imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: TickerMode(
                        enabled: !_navOpen,
                        child: Focus(
                          focusNode: _contentScope,
                          onKeyEvent: _onContentKey,
                          child: Padding(
                            // Overscan-safe inset. Left gap clears the persistent
                            // collapsed rail so page content never sits under it.
                            padding: const EdgeInsets.fromLTRB(
                              _kNavCollapsed + 4,
                              24,
                              24,
                              16,
                            ),
                            child: TvShellTabScope(
                              activeIndex: _index,
                              child: IndexedStack(
                                index: _index,
                                children: [
                                  for (var i = 0; i < pages.length; i++)
                                    ExcludeFocus(
                                      excluding: i != _index,
                                      // IndexedStack exposes only its painted child.
                                      // Toggling ExcludeSemantics while tvOS dispatches a
                                      // scroll semantics action triggers Flutter's
                                      // _debugDoingSemantics assertion.
                                      child: _pageAt(i, pages),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Frost the whole page while the dock owns focus. Keep this
                // below the rail so its labels and focus highlight stay sharp.
                Positioned.fill(
                  child: IgnorePointer(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: _navOpen ? 1 : 0),
                      duration: _dockDuration,
                      curve: Curves.easeOutCubic,
                      builder: (context, amount, _) {
                        if (amount == 0) return const SizedBox.shrink();
                        // Blur is a fixed, cached layer on the page. Only
                        // tint opacity animates here; avoid a full-screen
                        // backdrop blur recalculation on every animation frame.
                        return ColoredBox(
                          key: const ValueKey('tv-nav-acrylic'),
                          color: AppColors.bg.withValues(alpha: 0.72 * amount),
                        );
                      },
                    ),
                  ),
                ), // ── Nav rail (icon strip ⇄ labelled drawer) ───────────────────
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: 0,
                  child: Focus(
                    focusNode: _railScope,
                    onKeyEvent: _onRailKey,
                    // Expand while focus is anywhere in the rail zone; collapse
                    // to the icon strip when it leaves (content is focused).
                    onFocusChange: (hasFocus) {
                      if (hasFocus != _navOpen) {
                        setState(() => _navOpen = hasFocus);
                      }
                    },
                    child: AnimatedContainer(
                      key: const ValueKey('tv-nav-slide'),
                      width: _navOpen ? _kNavExpanded : _kNavCollapsed,
                      duration: _dockDuration,
                      curve: Curves.easeOutCubic,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: AlignmentDirectional.centerStart,
                          minWidth: _kNavExpanded,
                          maxWidth: _kNavExpanded,
                          child: SizedBox(
                            width: _kNavExpanded,
                            child: RepaintBoundary(child: _railColumn()),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
