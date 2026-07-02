import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../downloads/downloads_screen.dart';
import '../home/home_screen.dart';
import '../home/my_list_screen.dart';
import '../home/search_screen.dart';
import '../settings/settings_screen.dart';
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

/// App-level navigation shell — four tabs via a [NavigationBar].
///
/// Uses [IndexedStack] so each screen preserves its scroll/state when
/// the user switches tabs.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  static const int _searchTab = 1;

  int _index = 0;

  /// Bumped each time the Search tab is (re)selected so the search screen can
  /// auto-focus its field and pop the keyboard, without stealing focus while
  /// the tab sits idle in the [IndexedStack].
  final ValueNotifier<int> _searchFocusSignal = ValueNotifier<int>(0);

  @override
  void dispose() {
    _searchFocusSignal.dispose();
    super.dispose();
  }

  void _onTabSelected(int i) {
    setState(() => _index = i);
    if (i == _searchTab) _searchFocusSignal.value++;
  }

  /// The five tab pages: the four from [buildShellPages] with [DownloadsScreen]
  /// inserted between My List (index 2) and Settings — the same slot the TV
  /// rail uses, keeping both shells identical.
  List<Widget> _pages() {
    final shared = buildShellPages(_searchFocusSignal);
    return [
      ...shared.sublist(0, 3), // Home, Search, My List
      const DownloadsScreen(), // Downloads
      shared.last, // Settings
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const RootShellTv();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: IndexedStack(
        index: _index,
        children: _pages(),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: AppColors.surface,
          indicatorColor: AppColors.accentSoft,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final isSelected = states.contains(WidgetState.selected);
            return AppText.overline.copyWith(
              color: isSelected ? AppColors.accent : AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final isSelected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: isSelected ? AppColors.accent : AppColors.textTertiary,
              size: 24,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _onTabSelected,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_filled),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.search),
              selectedIcon: Icon(Icons.search),
              label: 'Search',
            ),
            NavigationDestination(
              icon: Icon(Icons.bookmark_outline),
              selectedIcon: Icon(Icons.bookmark),
              label: 'My List',
            ),
            NavigationDestination(
              icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download),
              label: 'Downloads',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
