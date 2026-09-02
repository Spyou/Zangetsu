import 'package:flutter/widgets.dart';

/// Which page the TV shell's [IndexedStack] is showing.
///
/// Tab indices match [RootShellTv]'s page list: Home, Search, My List, …
abstract final class TvShellTab {
  static const int home = 0;
  static const int search = 1;
}

/// Published by [RootShellTv] so offstage tabs (Search, Schedule, …) can skip
/// heavy rebuilds while Home is visible. Pushed routes omit this scope.
class TvShellTabScope extends InheritedWidget {
  const TvShellTabScope({
    required this.activeIndex,
    required super.child,
    super.key,
  });

  final int activeIndex;

  static TvShellTabScope? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<TvShellTabScope>();
  }

  @override
  bool updateShouldNotify(TvShellTabScope oldWidget) {
    return oldWidget.activeIndex != activeIndex;
  }
}
