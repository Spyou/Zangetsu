import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// A tab the phone dock can show.
///
/// A STABLE identity, deliberately not a position. The shell used to key
/// everything off the slot number (`_index == 4` meant Settings, `== 1` meant
/// Schedule), which is fine while the five tabs are hardcoded and wrong the
/// moment the user can reorder or hide them.
enum DockTab {
  home('Home'),
  schedule('Schedule'),
  search('Search'),
  myList('My List'),
  downloads('Downloads'),
  history('History'),
  profile('Profile');

  const DockTab(this.label);

  /// What the dock prints under the icon.
  final String label;

  /// Profile is the only way into Settings — and Settings is where this very
  /// list is edited. Hiding it would strand the user with no way back, so it
  /// is pinned: always present, never reorderable off the end.
  bool get isPinned => this == DockTab.profile;

  /// Schedule is about airing anime, so it has nothing to say in a reading
  /// mode; the shell drops it there regardless of the user's order.
  bool get isAnimeOnly => this == DockTab.schedule;
}

/// Which tabs the phone dock shows, and in what order.
///
/// Phone only — the TV rail ([RootShellTv]) has its own fixed list and is
/// untouched by this.
class NavPrefs extends ChangeNotifier {
  static const String boxName = 'nav_prefs';
  static const String _tabsKey = 'tabs';

  /// The dock is a fixed-width capsule; below three it looks empty and above
  /// five the labels start colliding.
  static const int minTabs = 3;
  static const int maxTabs = 5;

  /// What the dock shipped with, and what a corrupt or empty value falls back
  /// to. Search sits centre for thumb reach.
  static const List<DockTab> defaultTabs = [
    DockTab.home,
    DockTab.schedule,
    DockTab.search,
    DockTab.myList,
    DockTab.profile,
  ];

  /// Opens the box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// The user's dock, or [defaultTabs].
  ///
  /// Everything stored is re-validated on the way out rather than trusted: a
  /// value written by an older build can name a tab that no longer exists, and
  /// a half-written list could otherwise leave the app with a dock it can't
  /// navigate out of.
  List<DockTab> get tabs {
    final raw = _box?.get(_tabsKey);
    if (raw is! List || raw.isEmpty) return defaultTabs;
    final out = <DockTab>[];
    for (final name in raw) {
      final tab = DockTab.values.where((t) => t.name == name).firstOrNull;
      if (tab != null && !out.contains(tab)) out.add(tab);
    }
    return _sanitize(out);
  }

  Future<void> setTabs(List<DockTab> tabs) async {
    final clean = _sanitize(tabs);
    await _box?.put(_tabsKey, [for (final t in clean) t.name]);
    notifyListeners();
  }

  Future<void> reset() async {
    await _box?.delete(_tabsKey);
    notifyListeners();
  }

  bool get isDefault => listEquals(tabs, defaultTabs);

  /// The validation the getter and setter both apply, exposed so the
  /// invariants can be tested without opening a Hive box.
  @visibleForTesting
  static List<DockTab> sanitizeForTest(List<DockTab> tabs) => _sanitize(tabs);

  /// Forces every invariant the dock depends on: the pinned tab is present,
  /// no duplicates, and the count is inside [minTabs]..[maxTabs]. Anything
  /// that can't be satisfied falls back to [defaultTabs] rather than leaving a
  /// dock the user can't recover from.
  static List<DockTab> _sanitize(List<DockTab> tabs) {
    final seen = <DockTab>{};
    final out = <DockTab>[
      for (final t in tabs)
        if (seen.add(t)) t,
    ];
    for (final pinned in DockTab.values.where((t) => t.isPinned)) {
      if (!out.contains(pinned)) out.add(pinned);
    }
    if (out.length > maxTabs) {
      // Drop from the end, but never the pinned tab.
      while (out.length > maxTabs) {
        final victim = out.lastWhere((t) => !t.isPinned, orElse: () => out.last);
        out.remove(victim);
      }
    }
    if (out.length < minTabs) return defaultTabs;
    return List.unmodifiable(out);
  }
}
