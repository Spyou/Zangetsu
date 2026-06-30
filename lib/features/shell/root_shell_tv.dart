import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_focusable.dart';
import '../downloads/downloads_screen.dart';
import 'root_shell.dart';

/// TV-only navigation shell: a left rail + an [IndexedStack] of pages.
///
/// Rendered when [AppMode.isTv] is true (gated in [RootShell.build]). The
/// phone [RootShell] and its [NavigationBar] are completely unchanged.
///
/// Pages reuse [buildShellPages] from [RootShell] (one source of truth) and
/// insert [DownloadsScreen] between My List and Settings — all cubits are
/// GetIt singletons so nothing is re-instantiated.
class RootShellTv extends StatefulWidget {
  const RootShellTv({super.key});

  @override
  State<RootShellTv> createState() => _RootShellTvState();
}

/// One entry in the TV left nav rail.
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

/// Nav-rail item definitions (label + icons). Order matches [_RootShellTvState._pages].
const List<_RailItem> _kRailItems = [
  _RailItem(
    label: 'Home',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_filled,
  ),
  _RailItem(
    label: 'Search',
    icon: Icons.search,
    selectedIcon: Icons.search,
  ),
  _RailItem(
    label: 'My List',
    icon: Icons.bookmark_outline,
    selectedIcon: Icons.bookmark,
  ),
  _RailItem(
    label: 'Downloads',
    icon: Icons.download_outlined,
    selectedIcon: Icons.download,
  ),
  _RailItem(
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

class _RootShellTvState extends State<RootShellTv> {
  static const int _searchRailItem = 1;

  int _index = 0;

  /// Bumped each time the Search rail item is selected so the embedded
  /// search screen can auto-focus its field — mirrors the phone shell's
  /// _searchFocusSignal pattern.
  final ValueNotifier<int> _searchFocusSignal = ValueNotifier<int>(0);

  // ── D-pad bridge: rail ↔ content ─────────────────────────────────────────
  //
  // Two FocusScopeNodes partition the screen into two focus zones.
  //
  // D-pad RIGHT from anywhere inside the rail zone: captured by [_onRailKey].
  // Re-focuses the scope's last-focused child (so the user returns where they
  // left off), or — on first entry — the first traversable descendant leaf
  // inside [_contentScope] (the hero Play button).  Focusing the bare scope
  // node was insufficient: it left no visible element highlighted.
  //
  // D-pad LEFT from anywhere inside the content zone: captured by
  // [_onContentKey] with an edge-gate.  It first attempts an intra-content
  // leftward traversal via [FocusManager.instance.primaryFocus.focusInDirection].
  // Only when that returns false (the focused node is already at the left edge)
  // does it fall back to [_railScope.requestFocus()].  Without the gate, every
  // left press in a poster row ejected the user to the rail.
  //
  // This bypasses Flutter's geometry-based directional traversal for the
  // rail→content and content→rail crossings, where rail items (top-left) and
  // content focusables (centre / hero area) share no obvious neighbour
  // relationship, while leaving intra-zone left/right traversal to Flutter.
  final FocusScopeNode _railScope =
      FocusScopeNode(debugLabel: 'tv-rail-scope');
  final FocusScopeNode _contentScope =
      FocusScopeNode(debugLabel: 'tv-content-scope');

  KeyEventResult _onRailKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      // Prefer the scope's last-focused child so the user returns to where they
      // left off.  On first entry, focusedChild is null — walk
      // traversalDescendants to find the first focusable leaf, ensuring focus
      // always lands on a real widget (never the bare scope node, which leaves
      // nothing visually highlighted on the screen).
      final lastFocused = _contentScope.focusedChild;
      if (lastFocused != null) {
        lastFocused.requestFocus();
      } else {
        final first = _contentScope.traversalDescendants
            .where((n) => n.canRequestFocus)
            .firstOrNull;
        first?.requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onContentKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      // Edge-gate: attempt intra-content leftward traversal first.
      // Only eject to the rail when the primary focus is at the left edge
      // (i.e. geometry-based traversal finds no left neighbour).  Without this
      // guard the old code ejected to the rail from ANY left press, so moving
      // between posters in a row or between hero buttons was impossible.
      final moved = FocusManager.instance.primaryFocus
              ?.focusInDirection(TraversalDirection.left) ??
          false;
      if (!moved) _railScope.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _searchFocusSignal.dispose();
    _railScope.dispose();
    _contentScope.dispose();
    super.dispose();
  }

  void _onItemSelected(int i) {
    setState(() => _index = i);
    if (i == _searchRailItem) _searchFocusSignal.value++;
  }

  /// TV pages: the four from [buildShellPages] with [DownloadsScreen] inserted
  /// between My List (index 2) and Settings (index 3).
  List<Widget> get _pages {
    final shared = buildShellPages(_searchFocusSignal);
    return [
      ...shared.sublist(0, 3), // Home, Search, My List
      const DownloadsScreen(),  // Downloads (TV-only nav slot)
      shared.last,              // Settings
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Row(
        children: [
          // ── Left nav rail ──────────────────────────────────────────────────
          // [_railScope] captures this entire zone so that:
          //   • arrowRight → _onRailKey hands focus to [_contentScope]
          //   • returning LEFT from content restores the last-focused rail item
          Focus(
            focusNode: _railScope,
            onKeyEvent: _onRailKey,
            child: Container(
              width: 200,
              color: AppColors.surface,
              child: SafeArea(
                right: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 24),
                    ..._kRailItems.asMap().entries.map((entry) {
                      final i = entry.key;
                      final item = entry.value;
                      final selected = _index == i;
                      return TvFocusable(
                        autofocus: i == 0,
                        onTap: () => _onItemSelected(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                selected ? item.selectedIcon : item.icon,
                                color: selected
                                    ? AppColors.accent
                                    : AppColors.textTertiary,
                                size: 24,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                item.label,
                                style: TextStyle(
                                  color: selected
                                      ? AppColors.accent
                                      : AppColors.textTertiary,
                                  fontSize: 15,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
          // ── Page area ──────────────────────────────────────────────────────
          // [_contentScope] captures this zone so that:
          //   • arrowLeft → _onContentKey hands focus back to [_railScope]
          //   • entering RIGHT from the rail focuses the most-recently-focused
          //     content child (or the first autofocus descendant on first entry)
          Expanded(
            child: Focus(
              focusNode: _contentScope,
              onKeyEvent: _onContentKey,
              child: IndexedStack(
                index: _index,
                children: _pages,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
