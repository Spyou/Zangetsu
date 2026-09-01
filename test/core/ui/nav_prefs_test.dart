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

    // Search left the dock for a Home header icon; Schedule left it for the
    // card row on Home, beside the Manga/Novel mode cards.
    test('the default dock has neither Search nor Schedule', () {
      expect(NavPrefs.defaultTabs, [
        DockTab.home,
        DockTab.myList,
        DockTab.profile,
      ]);
    });
  });

  // Task 17: DockTab.search was removed from the enum (Search moved to a
  // Home header icon, off the dock entirely). A user who saved their dock
  // while Search still existed has 'search' sitting in their Hive box as a
  // plain string — this drives that through the real getter (not
  // sanitizeForTest, which only ever sees already-parsed DockTabs) to prove
  // it degrades to a sane dock rather than crashing or leaving a blank slot.
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

    test('a saved list naming the old Search tab drops just that entry', () async {
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
      expect(out, [
        DockTab.home,
        DockTab.myList,
        DockTab.profile,
      ]);
    });

    test('a saved list that is mostly just Search falls back to default', () async {
      // Below minTabs once the unknown 'search' entry is stripped.
      await Hive.box(NavPrefs.boxName).put('tabs', ['search', 'profile']);
      final out = NavPrefs().tabs;

      expect(out, NavPrefs.defaultTabs);
    });
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

    // Task 17: Search is off the dock entirely, not just hidden by default —
    // there's no enum member left for it to offer.
    test('Search is not a dock tab any more', () {
      expect(DockTab.values.map((t) => t.name), isNot(contains('search')));
    });
  });
}
