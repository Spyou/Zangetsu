import 'package:flutter/material.dart';

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

  @override
  void dispose() {
    _searchFocusSignal.dispose();
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
          Container(
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
          // ── Page area ──────────────────────────────────────────────────────
          Expanded(
            child: IndexedStack(
              index: _index,
              children: _pages,
            ),
          ),
        ],
      ),
    );
  }
}
