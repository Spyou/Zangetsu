import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../search/browse_sources_screen.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/ui_strings.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/nav_prefs.dart';
import '../downloads/downloads_screen.dart';
import '../history/history_screen.dart';
import '../auth/auth_cubit.dart';
import '../home/cubit/home_cubit.dart';
import '../home/home_screen.dart';
import '../home/my_list_screen.dart';
import '../home/search_screen.dart';
import '../settings/settings_screen.dart';
import 'dock_icons.dart';
import 'mode_bar.dart';
import '../../core/ui/dock_visibility.dart';
import 'root_shell_tv.dart';

/// The four pages used by both [RootShell] (phone bottom nav) and
/// [RootShellTv] (TV left rail). Any change to the page set must be
/// reflected in BOTH shells; this single function is the one source of truth.
///
/// [searchFocusSignal] is bumped each time the Search rail item is
/// (re)selected on TV so the embedded search screen can auto-focus its
/// field. Phone has no Search dock tab any more — Search moved to a Home
/// header icon — so [RootShell] always passes null here.
List<Widget> buildShellPages(ValueNotifier<int>? searchFocusSignal) => [
  const HomeScreen(),
  SearchScreen(showBack: false, focusSignal: searchFocusSignal),
  const MyListScreen(),
  const SettingsScreen(),
];

/// App-level navigation shell — a reorderable dock (3-5 tabs, [NavPrefs])
/// via a custom floating capsule (frosted, hovering over the content; no
/// Material NavigationBar).
///
/// Uses [IndexedStack] so each screen preserves its scroll/state when
/// the user switches tabs.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin {
  /// The tab showing, by identity. Was an int index into a hardcoded five —
  /// which stopped meaning anything once the dock became reorderable.
  ///
  /// Starts wherever the user chose to land; [NavPrefs.startTab] falls back to
  /// the leftmost tab, so an untouched install still opens on Home.
  late DockTab _tab = _navPrefs.startTab;

  /// Whether the floating mode bar (Anime / Movie/TV / Manga / Novel) is
  /// showing above the dock. Z Mode only — the centre button that toggles it
  /// doesn't exist otherwise.
  bool _modeBarOpen = false;

  /// Falls back to an unregistered instance rather than throwing.
  ///
  /// Production always registers it; widget tests build this shell with only
  /// the deps they care about. A bare [NavPrefs] reads no Hive box and returns
  /// [NavPrefs.defaultTabs], which is the dock those tests expect anyway —
  /// same guard the bloc uses for ContentModeCubit.
  late final NavPrefs _navPrefs = sl.isRegistered<NavPrefs>()
      ? sl<NavPrefs>()
      : NavPrefs();

  /// Double-back-to-exit: timestamp of the last root Back press. A second Back
  /// within 2s exits the app; the first just shows the "press back again" toast.
  DateTime? _lastBackPress;

  /// Tab-switch entrance: the visible page swaps immediately and the INCOMING
  /// tab fades + slides up into place (200ms, ease-out). We never fade the old
  /// tab out to blank — that midpoint blank frame read as a stutter. The
  /// [IndexedStack] stays alive, so every tab keeps its scroll position and
  /// nothing is rebuilt during the animation (the page is a cached layer).
  late final AnimationController _switchCtrl;
  late final Animation<double> _switch;

  @override
  void initState() {
    super.initState();
    _switchCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1,
    );
    _switch = CurvedAnimation(parent: _switchCtrl, curve: Curves.easeOutCubic);
    _navPrefs.addListener(_onTabsChanged);
    ZModePrefs.revision.addListener(_onZMode);
  }

  /// The toggle changed: close the mode bar and, as a safety net, bounce off
  /// any tab that somehow stopped being visible.
  void _onZMode() {
    if (!mounted) return;
    // TV returns [RootShellTv] from [build], but this State is still the
    // parent. setState here rebuilds every tab (two 10-foot Homes + Search +
    // Schedule) and freezes the UI for seconds even on a HomeCubit cache hit.
    if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) return;
    setState(() {
      _modeBarOpen = false;
      final visible = _visibleTabs();
      if (!visible.contains(_tab)) _tab = visible.first;
    });
  }

  /// The dock was edited in Settings. If the tab we're on just got hidden,
  /// land somewhere that still exists instead of showing a page with no item.
  void _onTabsChanged() {
    if (!mounted) return;
    final visible = _visibleTabs();
    setState(() {
      if (!visible.contains(_tab)) _tab = visible.first;
    });
  }

  /// The dock as actually rendered. Every tab suits every content mode now
  /// that Schedule lives on Home instead (see `_scheduleCard` there), so this
  /// is just the user's order.
  List<DockTab> _visibleTabs() => _navPrefs.tabs;

  @override
  void dispose() {
    _navPrefs.removeListener(_onTabsChanged);
    ZModePrefs.revision.removeListener(_onZMode);
    _switchCtrl.dispose();
    super.dispose();
  }

  void _onTabSelected(DockTab tab) {
    if (tab == _tab) return; // Re-tapping the current tab: no transition.
    DockScrollCollapse.reset();
    setState(() => _tab = tab);
    _switchCtrl.forward(from: 0);
  }

  /// Root-level Back: the first press shows a toast, a second within 2s exits.
  /// Only reached when Back would otherwise close the app — deep screens
  /// (detail, player, …) are pushed above this shell and pop normally.
  void _onBack() {
    // A sub-page inside the current tab (an open Settings section, an active
    // search) owns this Back — its own PopScope handles it in the same event.
    // Both PopScopes share this route, so Flutter fires ours too; bail so we
    // don't flash the exit toast over a normal in-tab back-out.
    if (shellBackIntercepted.value) return;
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    // FToast (part of fluttertoast) rather than the plain showToast, so the
    // pill can sit ABOVE the floating dock — showToast has no bottom offset.
    (FToast()..init(context)).showToast(
      gravity: ToastGravity.BOTTOM,
      toastDuration: const Duration(seconds: 2),
      child: Container(
        margin: const EdgeInsets.only(bottom: kDockClearance),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xF01C1C1E),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          context.l10n.pressBackAgainToExit,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
  }

  /// One page per visible tab, in the same order the dock draws them, so the
  /// [IndexedStack] index is just the tab's position in that list.
  ///
  /// [buildShellPages] stays the shared Home/Search/My List/Settings set that
  /// the TV rail also builds from — untouched, so TV is unaffected. Search is
  /// no longer a phone dock tab (it's a Home header icon now), so this never
  /// places `shared[1]` — it's still built, just unused here, the same way
  /// Settings only ever takes `shared.last`.
  List<Widget> _pagesFor(List<DockTab> tabs) {
    final shared = buildShellPages(null);
    return [
      for (final t in tabs)
        switch (t) {
          DockTab.home => shared[0],
          DockTab.myList => shared[2],
          DockTab.profile => shared.last, // Settings, shown as "Profile"
          // Both normally get pushed with a back button; as tabs they own the
          // whole screen, so their own back affordance is suppressed.
          DockTab.downloads => const DownloadsScreen(showBack: false),
          DockTab.history => const HistoryScreen(showBack: false),
          DockTab.sources => const BrowseSourcesScreen(),
        },
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const RootShellTv();
    return PopScope(
      // Intercept Back at the app root: first press toasts, second exits.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: BlocListener<ContentModeCubit, ContentMode>(
        bloc: sl<ContentModeCubit>(),
        listenWhen: (prev, curr) => prev != curr,
        listener: (context, mode) {
          // Always rebuild: the dock's items are computed in build(), so the
          // mode change has to reach it. No tab has to be bounced off any
          // more — the dock is the same in every mode now that Schedule is
          // not in it.
          setState(() {});
        },
        child: Scaffold(
          backgroundColor: AppColors.bg,
          // Content runs under the floating dock (screens keep their own bottom
          // padding so the last row scrolls clear of it).
          extendBody: true,
          body: NotificationListener<ScrollNotification>(
            // One place, so no screen has to know the dock exists. Returns
            // false throughout — it reads the scroll, never eats it.
            onNotification: DockScrollCollapse.onNotification,
            child: Builder(
              builder: (context) {
                final visible = _visibleTabs();
                final active = visible.indexOf(_tab);
                return AnimatedBuilder(
                  animation: _switch,
                  builder: (context, child) {
                    final v = _switch.value;
                    // Incoming tab fades in from 0.4 and slides up 20px. Never blanks.
                    return Opacity(
                      opacity: 0.4 + 0.6 * v,
                      child: Transform.translate(
                        offset: Offset(0, (1 - v) * 20),
                        child: child,
                      ),
                    );
                  },
                  // RepaintBoundary → the page is a single cached layer the transition
                  // just composites (opacity + translate), so no repaint per frame.
                  child: RepaintBoundary(
                    child: IndexedStack(
                      // indexOf can be -1 for one frame if the mode flipped before
                      // the listener ran; clamp rather than throw.
                      index: active < 0 ? 0 : active,
                      children: _pagesFor(visible),
                    ),
                  ),
                );
              },
            ),
          ),
          bottomNavigationBar: ValueListenableBuilder<bool>(
            valueListenable: dockHiddenBySection,
            builder: (context, sectionOpen, _) {
              // Slide the dock away only when a Settings section is open AND the
              // Settings (Profile, last) tab is the one showing — every other tab
              // keeps its dock.
              final hide = sectionOpen && _tab == DockTab.profile;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ZModePrefs.enabled)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: BlocBuilder<ContentModeCubit, ContentMode>(
                        bloc: sl<ContentModeCubit>(),
                        builder: (_, mode) => ModeBar(
                          open: _modeBarOpen,
                          current: (mode, ZModePrefs.streamKind),
                          onPicked: (m, k) async {
                            setState(() => _modeBarOpen = false);
                            await ZModePrefs.setStreamKind(k);
                            await sl<ContentModeCubit>().setMode(m);
                            if (m != ContentMode.anime) {
                              sl<HomeCubit>().load(reset: true);
                            }
                          },
                        ),
                      ),
                    ),
                  // Collapse the SLOT as well as sliding the dock out of it.
                  // The dock is this Scaffold's bottomNavigationBar and the
                  // shell sets extendBody, so its height lands in the body's
                  // MediaQuery bottom padding whether or not it is on screen.
                  // Sliding alone left an open Settings section reserving a
                  // dock's worth of space for a dock that wasn't there.
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 1, end: hide ? 0 : 1),
                    duration: const Duration(milliseconds: 240),
                    // Held at one end, then changed in a step — deliberately
                    // NOT eased across the whole 240ms.
                    //
                    // This factor is the dock's height, the dock is the
                    // Scaffold's bottomNavigationBar, and the shell sets
                    // extendBody. So every distinct value here relays out the
                    // Scaffold and rebuilds the body — and the body is an
                    // IndexedStack, which builds EVERY tab, not just the one
                    // on screen. Easing it smoothly meant ~14 rebuilds of
                    // Home, My List and Sources for a dock animation, which
                    // measured 13-36ms of build per frame while raster sat
                    // at 3-5ms. It is why opening a Settings section stuttered
                    // and opening Playback or History never did: only the
                    // in-page sections hide the dock.
                    //
                    // Collapse late and expand early, so the slide below has
                    // its space for the whole of its travel either way.
                    curve: hide
                        ? const Interval(0.88, 1, curve: Curves.easeOutCubic)
                        : const Interval(0, 0.12, curve: Curves.easeOutCubic),
                    builder: (context, factor, child) => ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: factor,
                        child: child,
                      ),
                    ),
                    child: AnimatedSlide(
                      offset: hide ? const Offset(0, 1.6) : Offset.zero,
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                      child: IgnorePointer(
                        ignoring: hide,
                        // Scoped to the dock subtree on purpose. The dock's
                        // HEIGHT never changes below, so the Scaffold keeps its
                        // bottom inset and the body — an IndexedStack that
                        // builds every tab — is never rebuilt by this.
                        child: ValueListenableBuilder<bool>(
                          valueListenable: dockCollapsedByScroll,
                          builder: (context, collapsed, child) => _FloatingDock(
                            collapsed: collapsed,
                            tabs: _visibleTabs(),
                            active: _tab,
                            onSelected: _onTabSelected,
                            centre: ZModePrefs.enabled
                                ? BlocBuilder<ContentModeCubit, ContentMode>(
                                    bloc: sl<ContentModeCubit>(),
                                    builder: (_, mode) => ModeFab(
                                      open: _modeBarOpen,
                                      icon: iconForMode(
                                        mode,
                                        ZModePrefs.streamKind,
                                      ),
                                      onTap: () => setState(
                                        () => _modeBarOpen = !_modeBarOpen,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The frosted floating capsule: blurred surface, hairline border, five
/// items. Active tab = the icon's solid accent twin + accent label — the
/// state change lives in the icon itself (deliberately not the Material
/// pill/indicator look).
class _FloatingDock extends StatelessWidget {
  const _FloatingDock({
    required this.tabs,
    required this.active,
    required this.onSelected,
    this.collapsed = false,
    this.centre,
  });

  /// Scrolled down far enough that the dock gives way: labels fade out and the
  /// pill draws in. The tabs stay put and stay tappable — see
  /// [dockCollapsedByScroll].
  final bool collapsed;

  /// Exactly what to draw, already ordered and already filtered for the
  /// content mode — the dock does no picking of its own any more.
  final List<DockTab> tabs;
  final DockTab active;
  final ValueChanged<DockTab> onSelected;

  /// The Z Mode centre button. Not a [DockTab] — it isn't reorderable,
  /// hideable, or counted toward the tab limit. Null when Z Mode is off.
  final Widget? centre;

  Widget _item(BuildContext context, DockTab t, double labels) =>
      t == DockTab.profile
      ? _ProfileDockItem(
          selected: active == t,
          onTap: () => onSelected(t),
          labelOpacity: labels,
        )
      : _DockItem(
          labelOpacity: labels,
          label: t.localizedLabel(context),
          glyph: dockGlyphFor(t),
          icon: _iconFor(t),
          selected: active == t,
          onTap: () => onSelected(t),
        );

  // Pieces of the dock's height, so the slot reserved below is measured rather
  // than guessed — a guess breaks the moment the system font scale moves.
  static const double _iconRow = 25;
  static const double _labelGap = 3;
  static const double _labelSize = 10;
  static const double _labelLeading = 1.2;
  static const double _itemVPad = 4;
  static const double _pillVPad = 18;
  static const double _fabOpen = 50;
  static const double _fabShut = 38;

  /// Width one tab gets in the collapsed pill. The items are [Expanded], so
  /// they always divide whatever width the pill has — narrowing it by a fixed
  /// amount just leaves the icons floating in wide cells. So the collapsed
  /// width is built up from this instead, and the pill ends up roughly the
  /// size of its icons.
  ///
  /// Width one tab gets collapsed. 48 is the guideline, and the pill's clip
  /// trims a few off it, so the real target lands near 44 — Apple's floor.
  ///
  /// Measured on device rather than assumed: at 40 this budget produced a
  /// 36-wide target. Inside the pill's ClipRRect the hit area and the painted
  /// width are the same thing, so this cannot be shrunk without shrinking the
  /// target with it.
  static const double _tabShut = 48;

  /// Minimum HEIGHT of a tab's tap area. The painted icon is 25 and the pill
  /// collapses to 56 — but a 27-tall target sitting just above the gesture bar
  /// is a miss waiting to happen, so the touchable box is held at 44 (Apple's
  /// floor) even when nothing is drawn in most of it.
  ///
  /// 48 is Android's floor. Free: the open row is 50 anyway (the centre
  /// button), and the collapsed row is paid for by dropping the pill's own
  /// padding 9 → 4 as it closes. Both states keep the exact height they had —
  /// 68 open, 56 closed — the space just moves from padding into the box you
  /// can actually hit.
  static const double _tapMin = 48;

  /// iOS-ish: almost all of the travel happens early, then it eases into place
  /// instead of stopping. Slower than a Material fling on purpose — this is a
  /// shape settling, not a thing arriving.
  static const Curve _ease = Cubic(0.32, 0.72, 0, 1);

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final half = tabs.length ~/ 2;
    final first = tabs.sublist(0, half);
    final rest = tabs.sublist(half);

    // The SLOT stays the size of the open dock, always. The pill shrinks
    // inside it and hangs from the bottom, so the Scaffold's bottom inset
    // never moves — and the body, an IndexedStack that builds every tab, is
    // never relaid out while you scroll.
    //
    // Taken through the text scaler, not from a constant: at a larger system
    // font the label is taller, and a slot that assumed 10px would clip the
    // labels off the dock for exactly the people who need them most.
    final labelRow =
        _labelGap +
        MediaQuery.textScalerOf(context).scale(_labelSize) * _labelLeading;
    final openInner = math.max(
      math.max(_itemVPad + _iconRow + labelRow, _tapMin),
      centre != null ? _fabOpen : 0.0,
    );
    // Slack, because predicting a text line to the pixel is a losing game —
    // font, locale and platform metrics all move it. The constraint below is a
    // MINIMUM, not a fixed height, so being wrong costs a pixel of dead space
    // instead of a RenderFlex overflow.
    final slot = openInner + _pillVPad + bottomInset + 12 + 4;

    return ConstrainedBox(
      // minHeight, deliberately: the slot holds the open dock's size so the
      // Scaffold's inset never moves while the pill shrinks inside it — but if
      // the open dock ever needs MORE (a big system font), it gets it rather
      // than clipping the labels off.
      constraints: BoxConstraints(minHeight: slot),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: collapsed ? 1 : 0),
        duration: const Duration(milliseconds: 340),
        curve: _ease,
        builder: (context, t, _) => Align(
          alignment: Alignment.bottomCenter,
          child: _pill(context, bottomInset, t, first, rest),
        ),
      ),
    );
  }

  /// The dock at collapse fraction [t] — 0 open, 1 icons-only.
  ///
  /// Nothing here is given a fixed height: the label row folds away inside
  /// each item and the centre button scales down, so the pill takes whatever
  /// height its contents actually need and can't be made to overflow.
  Widget _pill(
    BuildContext context,
    double bottomInset,
    double t,
    List<DockTab> first,
    List<DockTab> rest,
  ) {
    // Collapsed width is derived, not a fixed inset: it is what the icons
    // actually need, so three tabs draw in further than four and a narrow
    // phone doesn't end up with a pill wider than its contents.
    final width = MediaQuery.sizeOf(context).width;
    final shutWidth =
        tabs.length * _tabShut +
        (centre != null ? _fabShut + 12 : 0) +
        12; // the pill's own horizontal padding
    // Never past the open inset — on a screen too narrow to shrink into, the
    // dock simply stays where it is rather than growing.
    final shutSide = math.max(16.0, (width - shutWidth) / 2);
    final side = 16 + (shutSide - 16) * t;
    final labels = 1 - t;
    final fab = _fabOpen - (_fabOpen - _fabShut) * t;
    // 9 open, 4 closed — the room the taller tap box needs, given back.
    final pillPad = 9 - 5 * t;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 0, side, bottomInset + 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: pillPad),
            decoration: BoxDecoration(
              // Light enough that content ghosts through even on dark
              // screens (My List / Settings) — 0.75 read as a solid slab
              // anywhere the page behind wasn't bright.
              color: AppColors.surface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: Row(
              children: [
                for (final tab in first) _item(context, tab, labels),
                if (centre != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    // Sized down rather than scaled in place: it is the tallest
                    // thing in the row, so leaving it at 50 would hold the
                    // whole dock open no matter what the tabs did.
                    child: SizedBox(
                      width: fab,
                      height: fab,
                      child: FittedBox(fit: BoxFit.contain, child: centre!),
                    ),
                  ),
                for (final tab in rest) _item(context, tab, labels),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// (outline, filled) Material icons for tabs with no hand-drawn glyph.
(IconData, IconData)? _iconFor(DockTab t) => switch (t) {
  DockTab.downloads => (Icons.download_outlined, Icons.download_rounded),
  DockTab.history => (Icons.history_outlined, Icons.history_rounded),
  DockTab.sources => (Icons.extension_outlined, Icons.extension_rounded),
  _ => null,
};

/// A quick spring "pop" for a dock icon the moment its tab becomes selected
/// (scale 0.7 → 1.0 with a soft overshoot). Deselection doesn't animate —
/// the motion belongs to the tab you're landing on.
class _DockPop extends StatelessWidget {
  const _DockPop({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(selected), // restart the tween when selection flips
      tween: Tween(begin: selected ? 0.7 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutBack,
      builder: (_, v, c) => Transform.scale(scale: v, child: c),
      child: child,
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.label,
    required this.glyph,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.labelOpacity = 1,
  });

  /// 1 whole, 0 collapsed. Drives both the fade AND the row's height, so the
  /// label takes its space with it when it goes.
  final double labelOpacity;

  final String label;

  /// Hand-drawn glyph; null when [icon] carries the tab instead.
  final DockGlyph? glyph;

  /// (outline, filled) Material pair, used when [glyph] is null.
  final (IconData, IconData)? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Expanded(
      // The name lives here, not on the Text below: collapsed, that Text has
      // zero height and drops out of the tree, and a screen reader was left
      // with four unlabelled buttons.
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        container: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _FloatingDock._tapMin),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 25,
                      child: Center(
                        child: _DockPop(
                          selected: selected,
                          child: glyph != null
                              ? DockIcon(glyph!, color: color, filled: selected)
                              : Icon(
                                  selected ? icon!.$2 : icon!.$1,
                                  color: color,
                                  size: 23,
                                ),
                        ),
                      ),
                    ),
                    // Folded away, not just faded: heightFactor takes the row's
                    // height with it, which is what lets the pill actually shrink.
                    ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: labelOpacity,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: ExcludeSemantics(
                            child: Opacity(
                              opacity: labelOpacity,
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.2,
                                  letterSpacing: 0.1,
                                  color: color,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
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
        ),
      ),
    );
  }
}

/// The Profile tab — the user's avatar when signed in (accent ring while
/// active), a plain person glyph otherwise. Opens the same Settings screen
/// the gear used to.
class _ProfileDockItem extends StatelessWidget {
  const _ProfileDockItem({
    required this.selected,
    required this.onTap,
    this.labelOpacity = 1,
  });

  /// See [_DockItem.labelOpacity].
  final double labelOpacity;

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Expanded(
      // See [_DockItem]: the name has to survive the label folding away.
      child: Semantics(
        label: 'Profile',
        button: true,
        selected: selected,
        container: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _FloatingDock._tapMin),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 25,
                      child: Center(
                        child: _DockPop(
                          selected: selected,
                          child: BlocBuilder<AuthCubit, AuthState>(
                            builder: (context, auth) {
                              final ring = selected
                                  ? Border.all(
                                      color: AppColors.accent,
                                      width: 1.8,
                                    )
                                  : null;
                              if (auth.isLoggedIn) {
                                final initial = auth.displayName.isNotEmpty
                                    ? auth.displayName[0].toUpperCase()
                                    : '?';
                                return Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: ring,
                                    color: AppColors.surface2,
                                    image: auth.avatarUrl != null
                                        ? DecorationImage(
                                            image: CachedNetworkImageProvider(
                                              auth.avatarUrl!,
                                            ),
                                            fit: BoxFit.cover,
                                          )
                                        : null,
                                  ),
                                  alignment: Alignment.center,
                                  child: auth.avatarUrl == null
                                      ? Text(
                                          initial,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            color: selected
                                                ? AppColors.accent
                                                : AppColors.textPrimary,
                                          ),
                                        )
                                      : null,
                                );
                              }
                              // Signed out — quiet person glyph in a hairline circle.
                              return Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border:
                                      ring ??
                                      Border.all(color: color, width: 1.4),
                                ),
                                child: Icon(
                                  Icons.person_outline,
                                  size: 15,
                                  color: color,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    // Folded away, not just faded: heightFactor takes the row's
                    // height with it, which is what lets the pill actually shrink.
                    ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: labelOpacity,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: ExcludeSemantics(
                            child: Opacity(
                              opacity: labelOpacity,
                              child: Text(
                                'Profile',
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.2,
                                  letterSpacing: 0.1,
                                  color: color,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
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
        ),
      ),
    );
  }
}
