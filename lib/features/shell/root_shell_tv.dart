import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_focusable.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens_tv.dart';
import '../auth/reconnect.dart';
import '../downloads/downloads_screen.dart';
import '../../l10n/l10n.dart';
import '../home/cubit/home_cubit.dart';
import '../schedule/schedule_screen.dart';
import 'root_shell.dart';
import 'tv_source_picker.dart';

/// Collapsed (icon-only) and expanded (labelled) drawer widths.
const double _kNavCollapsed = 74;
const double _kNavExpanded = 312;

/// Horizontal inset inside the rail column (room for pill focus chrome).
const double _kRailHPad = 6;

/// Width of the icon/logo column. Sized so icons sit dead-centre in the
/// *visible* collapsed rail: the column has [_kRailHPad] on each side, so
/// using full [_kNavCollapsed] here would shift every icon to the right.
const double _kIconSlot = _kNavCollapsed - 2 * _kRailHPad;

/// TV-only navigation shell: a collapsing left drawer over an [IndexedStack].
///
/// Rendered when [AppMode.isTv] is true (gated in [RootShell.build]). The phone
/// [RootShell] and its [NavigationBar] are completely unchanged.
///
/// The drawer overlays the page area on the left. It shows a slim icon rail by
/// default and pops open to a full labelled drawer whenever focus is in the
/// rail zone — Apple-TV style. Pages reuse [buildShellPages] from [RootShell]
/// (one source of truth); all cubits are GetIt singletons so nothing is
/// re-instantiated.
class RootShellTv extends StatefulWidget {
  const RootShellTv({super.key});

  @override
  State<RootShellTv> createState() => _RootShellTvState();
}

/// One entry in the TV nav.
class _RailItem {
  const _RailItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Nav item definitions (label + icons). Order matches [_RootShellTvState._pages].
const int _kRailItemCount = 6;

List<_RailItem> _railItems(BuildContext context) {
  final l = context.l10n;
  return [
    _RailItem(
      label: l.home,
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_filled,
    ),
    _RailItem(
      label: l.search,
      icon: Icons.search,
      selectedIcon: Icons.search,
    ),
    _RailItem(
      label: l.myList,
      icon: Icons.bookmark_outline,
      selectedIcon: Icons.bookmark,
    ),
    _RailItem(
      label: l.downloads,
      icon: Icons.download_outlined,
      selectedIcon: Icons.download,
    ),
    _RailItem(
      label: l.schedule,
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month,
    ),
    _RailItem(
      label: l.settingsTitle,
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
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
  bool _navOpen = false; // drawer expanded ⇔ focus is in the rail zone
  DateTime? _lastBackPress;

  final ValueNotifier<int> _searchFocusSignal = ValueNotifier<int>(0);

  // ── D-pad bridge: rail ↔ content (unchanged from the original) ────────────
  final FocusScopeNode _railScope = FocusScopeNode(debugLabel: 'tv-rail-scope');
  final FocusScopeNode _contentScope =
      FocusScopeNode(debugLabel: 'tv-content-scope');

  // One focus node per nav item so entering the rail can land straight on the
  // CURRENT page's item (so you always see where you are).
  final List<FocusNode> _navNodes =
      List.generate(_kRailItemCount, (_) => FocusNode());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recoverFocusIfNeeded();
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

  /// Move focus into the rail so the drawer expands (its onFocusChange drives
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
    _searchFocusSignal.dispose();
    _railScope.dispose();
    _contentScope.dispose();
    for (final n in _navNodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// Display name for a source id (mirrors SourceSwitcher._label).
  String _sourceLabel(String id) {
    if (id.startsWith('cs:')) {
      try {
        final name = sl<CloudStreamManager>().get(id)?.displayName;
        if (name != null && name.isNotEmpty) return 'CS · $name';
      } catch (_) {}
      return id;
    }
    if (id.startsWith('ani:')) {
      try {
        final name = sl<AniyomiManager>().get(id)?.displayName;
        if (name != null && name.isNotEmpty) return 'Ani · $name';
      } catch (_) {}
      return id;
    }
    try {
      final entry = sl<ProviderRegistry>().entryFor(id);
      if (entry != null && entry.displayName.isNotEmpty) return entry.displayName;
      return entry?.name ?? id;
    } catch (_) {
      return id;
    }
  }

  void _onItemSelected(int i) {
    setState(() {
      _index = i;
      if (isAppleTv) _mountedPages.add(i);
    });
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
    if (isAppleTv) {
      final ok = await sl<ProviderRegistry>()
          .ensureRuntimeLoaded(sourceId)
          .catchError((_) => false);
      if (!ok || sl<ProviderManager>().get(sourceId) == null) {
        return;
      }
    }
    sl<HomeCubit>().load(reset: true);
  }

  void _handlePopInvoked(bool didPop, dynamic result) {
    if (didPop) return;
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
    final shared = buildShellPages(_searchFocusSignal);
    return [
      ...shared.sublist(0, 3), // Home, Search, My List
      const DownloadsScreen(),
      const ScheduleScreen(),
      shared.last, // Settings
    ];
  }

  Widget _pageAt(int index, List<Widget> pages) {
    if (!isAppleTv || _mountedPages.contains(index)) return pages[index];
    return const SizedBox.shrink();
  }

  // ── Drawer pieces ─────────────────────────────────────────────────────────

  /// Brand lockup at the top of the rail: the square app icon is always shown
  /// (so the collapsed rail never looks blank), and the wordmark fades in beside
  /// it when the drawer opens.
  Widget _brand() {
    return Row(
      children: [
        // Logo centered in the icon slot so it sits dead-centre when collapsed
        // and lines up with the nav icons below.
        SizedBox(
          width: _kIconSlot,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset('assets/icon/app_icon.png',
                  width: 30, height: 30, fit: BoxFit.cover),
            ),
          ),
        ),
        if (_navOpen) ...[
          Expanded(
            child: Image.asset(
              'assets/icon/wordmark.png',
              key: const ValueKey('tv-rail-wordmark'),
              height: 18,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            ),
          ),
          const SizedBox(width: 12),
        ],
      ],
    );
  }

  /// Source indicator — unchanged behaviour (opens [TvSourcePicker]); label
  /// fades in when open.
  Widget _sourceIndicator() {
    return BlocBuilder<ActiveSourceCubit, String>(
      builder: (context, sourceId) {
        return TvFocusable(
          key: const ValueKey('tv-source-indicator'),
          variant: TvFocusVariant.pill,
          onTap: () {
            showDialog<void>(
              context: context,
              barrierColor: Colors.black54,
              builder: (_) => BlocProvider<ActiveSourceCubit>.value(
                value: context.read<ActiveSourceCubit>(),
                child: TvSourcePicker(currentId: sourceId),
              ),
            );
          },
          builder: (focused) {
            final label = _sourceLabel(sourceId);
            final clean = label.replaceFirst(RegExp(r'^(CS|Ani) · '), '');
            final nameColor = focused ? Colors.black : AppColors.textPrimary;
            final lblColor =
                focused ? const Color(0xFF5A5A5A) : AppColors.textTertiary;
            final iconColor = focused ? Colors.black : AppColors.textSecondary;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: _kIconSlot,
                    child: Center(
                      child: Icon(Icons.swap_horiz_rounded,
                          size: 26, color: iconColor),
                    ),
                  ),
                  Expanded(
                    child: _navOpen
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                context.l10n.sourceNavLabel,
                                style: TextStyle(
                                  color: lblColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                clean,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: nameColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (_navOpen) const SizedBox(width: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _navItem(int i, _RailItem item) {
    final selected = _index == i;
    return TvFocusable(
      focusNode: _navNodes[i],
      variant: TvFocusVariant.pill,
      semanticLabel: item.label,
      onTap: () => _onItemSelected(i),
      builder: (focused) {
        final Color fg = focused
            ? Colors.black
            : (selected ? AppColors.textPrimary : AppColors.textTertiary);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: _kIconSlot,
                child: Center(
                  child: Icon(
                    selected ? item.selectedIcon : item.icon,
                    color: focused
                        ? Colors.black
                        // Active tab reads from the filled glyph + bright white,
                        // not a red tint — keeps the rail premium and calm.
                        : (selected ? AppColors.textPrimary : AppColors.textTertiary),
                    size: 26,
                  ),
                ),
              ),
              Expanded(
                child: _navOpen
                    ? ExcludeSemantics(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            color: fg,
                            fontSize: 18,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              if (_navOpen) const SizedBox(width: 12),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmLogout() async {
    final auth = context.read<AuthCubit>();
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogCtx) => Align(
        alignment: const Alignment(-0.72, -0.42), // near the profile (top-left)
        child: TvLogoutSheet(
          onConfirm: () async {
            Navigator.of(dialogCtx).pop();
            // Back the library up first (if we have a live session) so the
            // logout-time clearLocal can't lose an un-synced library.
            await backupLibraryIfPossible();
            await auth.logout();
          },
          onCancel: () => Navigator.of(dialogCtx).pop(),
        ),
      ),
    );
  }

  /// Account row pinned to the BOTTOM of the drawer (like the mockup). Always
  /// visible: signed in → avatar + name (OK opens the log-out popup); signed
  /// out → a placeholder + "Sign in" (OK opens the TV login screen).
  Widget _avatarBlock() {
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, auth) {
        final loggedIn = auth.isLoggedIn;
        final name = loggedIn ? auth.displayName : context.l10n.signIn;
        final sub = loggedIn ? context.l10n.signedIn : context.l10n.syncYourListNav;
        final avatar = auth.avatarUrl;
        final initial =
            (loggedIn && name.isNotEmpty) ? name[0].toUpperCase() : null;
        return TvFocusable(
          key: const ValueKey('tv-nav-avatar'),
          variant: TvFocusVariant.pill,
          onTap: () {
            if (loggedIn) {
              _confirmLogout();
            } else {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LoginScreenTv()),
              );
            }
          },
          builder: (focused) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: _kIconSlot,
                  child: Center(
                    child: CircleAvatar(
                      radius: 19,
                      backgroundColor: AppColors.surface2,
                      backgroundImage: (avatar != null && avatar.isNotEmpty)
                          ? NetworkImage(avatar)
                          : null,
                      child: (avatar == null || avatar.isEmpty)
                          ? (initial != null
                              ? Text(initial,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800))
                              : const Icon(Icons.person_rounded,
                                  color: AppColors.textSecondary, size: 24))
                          : null,
                    ),
                  ),
                ),
                Expanded(
                  child: _navOpen
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: focused
                                        ? Colors.black
                                        : AppColors.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                            Text(sub,
                                maxLines: 1,
                                style: TextStyle(
                                    color: focused
                                        ? const Color(0xFF555555)
                                        : AppColors.textTertiary,
                                    fontSize: 12)),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                if (_navOpen) const SizedBox(width: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The full-width (expanded) drawer content column. It's ALWAYS laid out at
  /// [_kNavExpanded] wide inside an OverflowBox and clipped to the animated
  /// width, so collapsing/expanding just reveals more of the same column — the
  /// labels fade via their own AnimatedOpacity.
  Widget _railColumn() {
    return SafeArea(
      left: false,
      right: false,
      top: false,
      bottom: false,
      // Inset so pill scale (~1.04) + shadow stay inside the drawer bounds when
      // the parent uses Clip.none (avoids cropped focus chrome).
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _kRailHPad, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            _brand(), // Zangetsu wordmark, revealed when open
            const SizedBox(height: 8),
            _avatarBlock(), // profile
            const SizedBox(height: 6),
            _sourceIndicator(), // source switch right under the profile
            const SizedBox(height: 6),
            const Divider(
                height: 1, color: AppColors.hairline, indent: 16, endIndent: 16),
            const SizedBox(height: 6),
            // Spread nav items across the remaining height (Android-TV style) so
            // Settings stays visible at the bottom instead of clipping off.
            Expanded(
              child: SingleChildScrollView(
                clipBehavior: Clip.none,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < _kRailItemCount; i++)
                      _navItem(i, _railItems(context)[i]),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handlePopInvoked,
      child: BlocListener<ActiveSourceCubit, String>(
        listenWhen: (prev, curr) => prev != curr,
        listener: (context, sourceId) {
          if (isAppleTv && !tvosProvidersReady) return;
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
                left: _kNavCollapsed,
                child: Focus(
                  focusNode: _contentScope,
                  onKeyEvent: _onContentKey,
                  child: Padding(
                    // Overscan-safe inset. Extra left gap so page content
                    // (esp. Settings cards) doesn't sit flush against the rail.
                    padding: const EdgeInsets.fromLTRB(28, 24, 24, 16),
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
              // ── Drawer overlay (icon rail ⇄ full drawer) ──────────────────
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                child: Focus(
                  focusNode: _railScope,
                  onKeyEvent: _onRailKey,
                  // Expand while focus is anywhere in the rail zone; collapse
                  // when it leaves (i.e. content is focused).
                  onFocusChange: (hasFocus) {
                    if (hasFocus != _navOpen) setState(() => _navOpen = hasFocus);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    width: _navOpen ? _kNavExpanded : _kNavCollapsed,
                    margin: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF23242B), Color(0xFF141519)],
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55),
                          blurRadius: 40,
                          offset: const Offset(0, 20),
                        ),
                      ],
                    ),
                    // Always clip to the rounded drawer. Nav focus chrome is kept
                    // inside via [_railColumn] insets + scroll padding above.
                    clipBehavior: Clip.antiAlias,
                    child: OverflowBox(
                      minWidth: _kNavExpanded,
                      maxWidth: _kNavExpanded,
                      alignment: Alignment.centerLeft,
                      child: SizedBox(width: _kNavExpanded, child: _railColumn()),
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

/// Compact "Log out?" confirm card shown from the nav avatar. Kept top-level so
/// it can be widget-tested without the shell/DI. The "Log out" action
/// autofocuses; Back dismisses the hosting dialog.
class TvLogoutSheet extends StatelessWidget {
  const TvLogoutSheet({super.key, required this.onConfirm, this.onCancel});
  final VoidCallback onConfirm;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0F13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TvFocusable(
            autofocus: true,
            variant: TvFocusVariant.pill,
            onTap: onConfirm,
            builder: (focused) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
              child: Row(
                children: [
                  Icon(Icons.logout_rounded,
                      size: 20,
                      color: focused ? Colors.black : const Color(0xFFFF5C5C)),
                  const SizedBox(width: 12),
                  Text(context.l10n.logOut,
                      style: TextStyle(
                        color: focused ? Colors.black : const Color(0xFFFF5C5C),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      )),
                ],
              ),
            ),
          ),
          TvFocusable(
            variant: TvFocusVariant.pill,
            onTap: onCancel ?? () {},
            builder: (focused) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
              child: Row(
                children: [
                  Icon(Icons.close_rounded,
                      size: 20,
                      color: focused ? Colors.black : AppColors.textSecondary),
                  const SizedBox(width: 12),
                  Text(context.l10n.cancel,
                      style: TextStyle(
                        color: focused ? Colors.black : AppColors.textSecondary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
