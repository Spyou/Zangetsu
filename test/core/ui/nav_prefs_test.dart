import 'package:flutter_test/flutter_test.dart';
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
      final out = sanitized([DockTab.home, DockTab.search, DockTab.myList]);
      expect(out, contains(DockTab.profile),
          reason: 'Profile is the only route into Settings — losing it would '
              'strand the user with no way to fix their own dock');
    });

    test('duplicates are collapsed', () {
      final out = sanitized([
        DockTab.home,
        DockTab.home,
        DockTab.search,
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
        DockTab.search,
        DockTab.downloads,
        DockTab.home,
        DockTab.profile,
      ];
      expect(sanitized(wanted), wanted);
    });

    test('the default dock is itself valid', () {
      expect(sanitized(NavPrefs.defaultTabs), NavPrefs.defaultTabs);
    });
  });

  group('DockTab', () {
    test('only Profile is pinned', () {
      expect(DockTab.values.where((t) => t.isPinned), [DockTab.profile]);
    });

    test('only Schedule is anime-only', () {
      expect(DockTab.values.where((t) => t.isAnimeOnly), [DockTab.schedule]);
    });

    test('every tab has a label', () {
      for (final t in DockTab.values) {
        expect(t.label, isNotEmpty, reason: '${t.name} needs a dock label');
      }
    });
  });
}
