import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../auth/auth_cubit.dart';
import '../home/home_screen.dart';
import '../home/my_list_screen.dart';
import '../home/search_screen.dart';
import '../schedule/schedule_screen.dart';
import '../settings/settings_screen.dart';
import 'dock_icons.dart';
import '../../core/ui/dock_visibility.dart';
import 'root_shell_tv.dart';

/// The four pages used by both [RootShell] (phone bottom nav) and
/// [RootShellTv] (TV left rail). Any change to the page set must be
/// reflected in BOTH shells; this single function is the one source of truth.
///
/// [searchFocusSignal] is bumped each time the Search tab/rail-item is
/// (re)selected so the embedded search screen can auto-focus its field.
List<Widget> buildShellPages(ValueNotifier<int>? searchFocusSignal) => [
  const HomeScreen(),
  SearchScreen(showBack: false, focusSignal: searchFocusSignal),
  const MyListScreen(),
  const SettingsScreen(),
];

/// App-level navigation shell — five tabs via a custom floating dock
/// (frosted capsule hovering over the content; no Material NavigationBar).
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
  static const int _searchTab = 2;

  int _index = 0;

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

  /// Bumped each time the Search tab is (re)selected so the search screen can
  /// auto-focus its field and pop the keyboard, without stealing focus while
  /// the tab sits idle in the [IndexedStack].
  final ValueNotifier<int> _searchFocusSignal = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _switchCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1,
    );
    _switch = CurvedAnimation(parent: _switchCtrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _switchCtrl.dispose();
    _searchFocusSignal.dispose();
    super.dispose();
  }

  void _onTabSelected(int i) {
    if (i == _index) {
      // Re-tapping the current tab: no transition, just re-focus Search.
      if (i == _searchTab) _searchFocusSignal.value++;
      return;
    }
    setState(() => _index = i);
    if (i == _searchTab) _searchFocusSignal.value++;
    _switchCtrl.forward(from: 0);
  }

  /// Root-level Back: the first press shows a toast, a second within 2s exits.
  /// Only reached when Back would otherwise close the app — deep screens
  /// (detail, player, …) are pushed above this shell and pop normally.
  void _onBack() {
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
        margin: const EdgeInsets.only(bottom: 104),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xF01C1C1E),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Text(
          'Press BACK again to exit',
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
  }

  /// The five tab pages, in dock order: Home · Schedule · Search · My List ·
  /// Settings. Search sits centre (best thumb reach); [ScheduleScreen] takes
  /// the second slot. The last tab (Settings screen) is presented as "Profile"
  /// in the dock. [buildShellPages] yields Home/Search/My List/…/Settings.
  List<Widget> _pages() {
    final shared = buildShellPages(_searchFocusSignal);
    return [
      shared[0], // Home
      const ScheduleScreen(), // Schedule
      shared[1], // Search
      shared[2], // My List
      shared.last, // Settings (Profile tab)
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const RootShellTv();
    // Reading modes have no Schedule tab (it's omitted from the dock below).
    // If the mode flips to Manga/Novel while Schedule (tab 1) is showing,
    // bounce back to Home rather than leaving the user on a tab that no
    // longer has a dock item.
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
          if (mode.isReading && _index == 1) setState(() => _index = 0);
        },
        child: Scaffold(
          backgroundColor: AppColors.bg,
          // Content runs under the floating dock (screens keep their own bottom
          // padding so the last row scrolls clear of it).
          extendBody: true,
          body: AnimatedBuilder(
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
              child: IndexedStack(index: _index, children: _pages()),
            ),
          ),
          bottomNavigationBar: ValueListenableBuilder<bool>(
            valueListenable: dockHiddenBySection,
            builder: (context, sectionOpen, _) {
              // Slide the dock away only when a Settings section is open AND the
              // Settings (Profile, last) tab is the one showing — every other tab
              // keeps its dock.
              final hide = sectionOpen && _index == 4;
              return AnimatedSlide(
                offset: hide ? const Offset(0, 1.6) : Offset.zero,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: IgnorePointer(
                  ignoring: hide,
                  child: _FloatingDock(
                    index: _index,
                    onSelected: _onTabSelected,
                  ),
                ),
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
  const _FloatingDock({required this.index, required this.onSelected});

  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
            decoration: BoxDecoration(
              // Light enough that content ghosts through even on dark
              // screens (My List / Settings) — 0.75 read as a solid slab
              // anywhere the page behind wasn't bright.
              color: AppColors.surface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            // Schedule has no meaning in a reading mode (no airing anime to
            // track), so it's omitted there. The other items keep their
            // original onSelected index — nothing is renumbered — so tab
            // identity and the IndexedStack below stay untouched.
            child: BlocBuilder<ContentModeCubit, ContentMode>(
              bloc: sl<ContentModeCubit>(),
              builder: (context, mode) => Row(
                children: [
                  _DockItem(
                    label: 'Home',
                    glyph: DockGlyph.home,
                    selected: index == 0,
                    onTap: () => onSelected(0),
                  ),
                  if (!mode.isReading)
                    _DockItem(
                      label: 'Schedule',
                      glyph: DockGlyph.calendar,
                      selected: index == 1,
                      onTap: () => onSelected(1),
                    ),
                  _DockItem(
                    label: 'Search',
                    glyph: DockGlyph.search,
                    selected: index == 2,
                    onTap: () => onSelected(2),
                  ),
                  _DockItem(
                    label: 'My List',
                    glyph: DockGlyph.bookmark,
                    selected: index == 3,
                    onTap: () => onSelected(3),
                  ),
                  _ProfileDockItem(
                    selected: index == 4,
                    onTap: () => onSelected(4),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
    required this.selected,
    required this.onTap,
  });

  final String label;
  final DockGlyph glyph;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
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
                    child: DockIcon(glyph, color: color, filled: selected),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.1,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
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
  const _ProfileDockItem({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
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
                            ? Border.all(color: AppColors.accent, width: 1.8)
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
                                ring ?? Border.all(color: color, width: 1.4),
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
              const SizedBox(height: 3),
              Text(
                'Profile',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.1,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
