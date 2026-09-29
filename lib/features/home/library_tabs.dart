import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'cubit/my_list_cubit.dart';

/// One tab in the library row: a label, the test that fills its page, and the
/// long-press that manages it (categories only).
class LibraryTab {
  const LibraryTab({
    required this.id,
    required this.label,
    required this.count,
    required this.test,
    this.onLongPress,
  });

  /// Stable across rebuilds, so the selected tab survives the list changing
  /// under it — an index would silently move when a status empties out.
  final String id;
  final String label;

  /// Counted before the search box narrows anything, so the row still shows
  /// where the rest of the list is while you are typing.
  final int count;
  final bool Function(MyListEntry) test;
  final VoidCallback? onLongPress;
}

/// The status row and the grid it filters, as a real [TabBar]/[TabBarView]
/// pair.
///
/// Was a horizontal `ListView` of tap targets over a single grid rebuilt by
/// `setState`: correct, but the pages could not be swiped and the underline
/// jumped between tabs instead of tracking the gesture. The detail screen
/// already uses a TabController for the same job, so this matches it.
class LibraryTabs extends StatefulWidget {
  const LibraryTabs({
    required this.tabs,
    required this.selectedId,
    required this.onSelected,
    required this.bodyFor,
    this.onAdd,
  });

  final List<LibraryTab> tabs;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Widget Function(LibraryTab) bodyFor;

  /// Pinned to the right of the row rather than being its last item: it is an
  /// action, and a swipe should never land on it.
  final VoidCallback? onAdd;

  @override
  State<LibraryTabs> createState() => LibraryTabsState();
}

class LibraryTabsState extends State<LibraryTabs>
    with TickerProviderStateMixin {
  late TabController _c = _makeController();

  int get _wantedIndex {
    final i = widget.tabs.indexWhere((t) => t.id == widget.selectedId);
    return i < 0 ? 0 : i;
  }

  TabController _makeController() => TabController(
    length: widget.tabs.length,
    initialIndex: _wantedIndex,
    vsync: this,
  )..addListener(_onTabChanged);

  void _onTabChanged() {
    // Fires twice per tap (start and end of the animation) and mid-way through
    // a swipe; only the settled index is worth reporting up.
    if (_c.indexIsChanging || !mounted) return;
    final id = widget.tabs[_c.index].id;
    if (id != widget.selectedId) widget.onSelected(id);
  }

  @override
  void didUpdateWidget(LibraryTabs old) {
    super.didUpdateWidget(old);
    // A tab appearing or disappearing (a status emptying out, a category made)
    // invalidates the controller's length, which is fixed at construction.
    if (widget.tabs.length != _c.length) {
      _c.removeListener(_onTabChanged);
      _c.dispose();
      _c = _makeController();
    } else if (_c.index != _wantedIndex) {
      // Moved from outside — creating a category lands on its new tab.
      _c.animateTo(_wantedIndex);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onTabChanged);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 42,
          child: Row(
            children: [
              Expanded(
                // Rebuilt against the controller's animation so the labels
                // recolour with the underline as the page slides, instead of
                // snapping once the swipe settles.
                child: AnimatedBuilder(
                  animation: _c.animation ?? _c,
                  builder: (context, _) => TabBar(
                    controller: _c,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    padding: const EdgeInsets.only(left: 16),
                    labelPadding: const EdgeInsets.only(right: 22),
                    indicatorSize: TabBarIndicatorSize.label,
                    indicator: UnderlineTabIndicator(
                      borderSide: BorderSide(
                        color: AppColors.accent,
                        width: 2.5,
                      ),
                    ),
                    // The row sat under a hairline; the grid below it reads as
                    // its own block without one.
                    dividerColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    tabs: [
                      for (var i = 0; i < widget.tabs.length; i++)
                        _tab(widget.tabs[i], i),
                    ],
                  ),
                ),
              ),
              if (widget.onAdd != null)
                GestureDetector(
                  onTap: widget.onAdd,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(4, 8, 16, 10),
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
        const SizedBox(height: 8),
        Expanded(
          child: TabBarView(
            controller: _c,
            children: [for (final t in widget.tabs) widget.bodyFor(t)],
          ),
        ),
      ],
    );
  }

  Widget _tab(LibraryTab t, int i) {
    // Distance from this tab, so a half-finished swipe is half-coloured.
    final at = _c.animation?.value ?? _c.index.toDouble();
    final near = (1 - (at - i).abs()).clamp(0.0, 1.0);
    final label = Color.lerp(AppColors.textSecondary, AppColors.accent, near)!;
    final count = Color.lerp(AppColors.textTertiary, AppColors.accent, near)!;
    return Tab(
      height: 42,
      child: GestureDetector(
        onLongPress: t.onLongPress,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.label,
              style: AppText.body.copyWith(
                color: label,
                fontWeight: FontWeight.w700,
                fontSize: 14.5,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${t.count}',
              style: AppText.caption.copyWith(color: count, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
