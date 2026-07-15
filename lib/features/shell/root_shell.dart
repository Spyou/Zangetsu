import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../auth/auth_cubit.dart';
import '../home/home_screen.dart';
import '../home/my_list_screen.dart';
import '../home/search_screen.dart';
import '../schedule/schedule_screen.dart';
import '../settings/settings_screen.dart';
import 'dock_icons.dart';
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

  /// The tab we're transitioning to; the visible page swaps to it at the
  /// fade's trough.
  int _targetIndex = 0;

  /// Fade-through between tabs: a 0→1 run whose opacity dips to 0 at the
  /// midpoint (where we swap the visible page) and back to 1 — the old tab
  /// fades out, the new one fades in. The [IndexedStack] stays alive
  /// throughout, so every tab keeps its scroll position.
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fade;

  /// Bumped each time the Search tab is (re)selected so the search screen can
  /// auto-focus its field and pop the keyboard, without stealing focus while
  /// the tab sits idle in the [IndexedStack].
  final ValueNotifier<int> _searchFocusSignal = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1,
    );
    _fade = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 1,
      ),
    ]).animate(_fadeCtrl);
    _fadeCtrl.addListener(() {
      // Swap the visible page at the trough, once per run.
      if (_index != _targetIndex && _fadeCtrl.value >= 0.5) {
        setState(() => _index = _targetIndex);
        if (_index == _searchTab) _searchFocusSignal.value++;
      }
    });
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _searchFocusSignal.dispose();
    super.dispose();
  }

  void _onTabSelected(int i) {
    // Re-tapping the current tab: no transition, just re-focus Search.
    if (i == _index && !_fadeCtrl.isAnimating) {
      if (i == _searchTab) _searchFocusSignal.value++;
      return;
    }
    _targetIndex = i;
    _fadeCtrl.forward(from: 0);
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      // Content runs under the floating dock (screens keep their own bottom
      // padding so the last row scrolls clear of it).
      extendBody: true,
      body: AnimatedBuilder(
        animation: _fade,
        builder: (context, child) {
          final v = _fade.value;
          return Opacity(
            opacity: v,
            // A whisper of zoom on the incoming half sells the fade-through.
            child: Transform.scale(scale: 0.985 + 0.015 * v, child: child),
          );
        },
        child: IndexedStack(index: _index, children: _pages()),
      ),
      bottomNavigationBar: _FloatingDock(
        index: _index,
        onSelected: _onTabSelected,
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
            child: Row(
              children: [
                _DockItem(
                  label: 'Home',
                  glyph: DockGlyph.home,
                  selected: index == 0,
                  onTap: () => onSelected(0),
                ),
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
