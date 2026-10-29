import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';

// The dock used to be five hardcoded tabs addressed by position. Letting the
// user reorder and hide them means the stored list is now the source of truth,
// so every way it can be wrong has to resolve to a dock that still works —
// there is no other way back into Settings to fix it.

/// The same validation the getter and setter apply, without needing a box.
List<DockTab> sanitized(List<DockTab> tabs) => NavPrefs.sanitizeForTest(tabs);

void main() {
  group('NavPrefs invariants', () {
    test('the pinned tab is added back when missing', () {
      final out = sanitized([DockTab.home, DockTab.downloads, DockTab.myList]);
      expect(out, contains(DockTab.profile),
          reason: 'Profile is the only route into Settings — losing it would '
              'strand the user with no way to fix their own dock');
    });

    test('duplicates are collapsed', () {
      final out = sanitized([
        DockTab.home,
        DockTab.home,
        DockTab.downloads,
        DockTab.profile,
      ]);
      expect(out.where((t) => t == DockTab.home).length, 1);
    });

    test('too few tabs falls back to the default dock', () {
      expect(sanitized([DockTab.home]), NavPrefs.defaultTabs);
    });

    test('too many tabs is trimmed to the cap, keeping the pinned one', () {
      final out = sanitized(DockTab.values.toList());
      expect(out.length, NavPrefs.maxTabs);
      expect(out, contains(DockTab.profile));
    });

    test('a valid custom order is preserved exactly', () {
      final wanted = [
        DockTab.downloads,
        DockTab.history,
        DockTab.home,
        DockTab.profile,
      ];
      expect(sanitized(wanted), wanted);
    });

    test('the default dock is itself valid', () {
      expect(sanitized(NavPrefs.defaultTabs), NavPrefs.defaultTabs);
    });

    // Search is opt-in (header icon while it's off the bar); Schedule left
    // for the card row on Home. Sources went the other way — it was a header
    // icon and is now a destination, which is why Downloads is no longer a
    // default.
    test('the default dock has neither Search nor Schedule', () {
      expect(NavPrefs.defaultTabs, [
        DockTab.home,
        DockTab.myList,
        DockTab.sources,
        DockTab.profile,
      ]);
    });

    // The bar fits five icons and the mode switcher takes one of them
    // without being a DockTab, so the tab cap has to be four. Picking five
    // tabs used to draw a sixth icon and squeeze the row.
    test('the cap leaves a slot for the centre button', () {
      expect(NavPrefs.maxTabs, 4);
      expect(NavPrefs.defaultTabs.length, NavPrefs.maxTabs);
    });
  });

  // Task 17 follow-up: Search is a dock tab again (opt-in, off by default).
  // A user who saved their dock while it existed has 'search' sitting in
  // their Hive box as a plain string — this drives that through the real
  // getter to prove it resolves rather than dropping.
  group('NavPrefs.tabs against a legacy stored value', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('nav_prefs_legacy_test');
      Hive.init(dir.path);
      await NavPrefs.init();
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('a saved list naming Search resolves it; unknown entries drop', () async {
      // What NavPrefs.defaultTabs used to ship as, back when it had 5 slots.
      // The box key ('tabs') is the persisted format itself — see _tabsKey.
      await Hive.box(NavPrefs.boxName).put('tabs', [
        'home',
        'schedule',
        'search',
        'myList',
        'profile',
      ]);
      final out = NavPrefs().tabs;

      expect(out, contains(DockTab.profile));
      expect(out.length, greaterThanOrEqualTo(NavPrefs.minTabs));
      // Only the unknown 'schedule' entry drops — 'search' is a real tab now.
      expect(out, [
        DockTab.home,
        DockTab.search,
        DockTab.myList,
        DockTab.profile,
      ]);
    });

    test('a saved list that is mostly just Search falls back to default', () async {
      // Below minTabs: Search resolves but two tabs aren't a dock.
      await Hive.box(NavPrefs.boxName).put('tabs', ['search', 'profile']);
      final out = NavPrefs().tabs;

      expect(out, NavPrefs.defaultTabs);
    });

    test('Search is savable as a tab but is not a default one', () async {
      await NavPrefs().setTabs([
        DockTab.home,
        DockTab.search,
        DockTab.profile,
      ]);
      expect(NavPrefs().tabs, contains(DockTab.search));
      expect(NavPrefs.defaultTabs, isNot(contains(DockTab.search)));
      await NavPrefs().reset();
    });

    test('with nothing chosen, the app opens on the leftmost tab', () {
      expect(NavPrefs().startTab, NavPrefs.defaultTabs.first);
    });

    test('keep-dock-expanded is off by default', () {
      expect(NavPrefs().isDefault, isTrue);
    });

    test('extra glass blur starts on and can be turned off', () async {
      expect(NavPrefs().glassBlurEnabled, isTrue);

      await NavPrefs().setGlassBlurEnabled(false);
      expect(NavPrefs().glassBlurEnabled, isFalse);

      await NavPrefs().reset();
      expect(NavPrefs().glassBlurEnabled, isTrue);
    });

    test('liquid is the default, but a chosen dock is preserved', () async {
      expect(NavPrefs().style, NavBarStyle.liquid);

      await NavPrefs().setStyle(NavBarStyle.dock);
      expect(NavPrefs().style, NavBarStyle.dock);

      await NavPrefs().reset();
      expect(NavPrefs().style, NavBarStyle.liquid);
    });

    test('a chosen landing tab survives a restart', () async {
      await NavPrefs().setStartTab(DockTab.myList);

      expect(NavPrefs().startTab, DockTab.myList);
    });

    // Launch has to land somewhere the dock can navigate away from. A tab
    // that is no longer on the bar has no dock entry to return to.
    test('a landing tab that was since hidden falls back', () async {
      await NavPrefs().setStartTab(DockTab.sources);
      await NavPrefs().setTabs([DockTab.home, DockTab.myList, DockTab.profile]);

      expect(NavPrefs().startTab, DockTab.home);
    });

    test('resetting forgets the landing tab too', () async {
      await NavPrefs().setStartTab(DockTab.myList);
      await Hive.box(NavPrefs.boxName).put('keepDockExpanded', true);
      await NavPrefs().reset();

      expect(NavPrefs().startTab, NavPrefs.defaultTabs.first);
      expect(NavPrefs().isDefault, isTrue);
      expect(Hive.box(NavPrefs.boxName).get('keepDockExpanded'), isNull);
    });

    test(
      'keep-dock-expanded is persisted and participates in reset state',
      () async {
        await NavPrefs().setKeepDockExpanded(true);

        expect(NavPrefs().keepDockExpanded, isTrue);
        expect(NavPrefs().isDefault, isFalse);

        await NavPrefs().reset();

        expect(NavPrefs().isDefault, isTrue);
      },
    );
  });

  group('DockTab', () {
    test('only Profile is pinned', () {
      expect(DockTab.values.where((t) => t.isPinned), [DockTab.profile]);
    });

    // isAnimeOnly went with Schedule: it was that tab's only subject, and
    // every remaining tab suits every content mode.
    test('no tab is restricted to a content mode', () {
      expect(DockTab.values.map((t) => t.name), isNot(contains('schedule')));
    });

    test('every tab has a label', () {
      for (final t in DockTab.values) {
        expect(t.label, isNotEmpty, reason: '${t.name} needs a dock label');
      }
    });

    // Search is back as an opt-in dock tab — a real member, but absent from
    // the default dock so untouched installs look exactly as before.
    test('Search is a dock tab but not a default one', () {
      expect(DockTab.values.map((t) => t.name), contains('search'));
      expect(NavPrefs.defaultTabs, isNot(contains(DockTab.search)));
    });
  });
}
