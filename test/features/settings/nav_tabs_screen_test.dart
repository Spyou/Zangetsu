// Task 11: Search used to be excluded from the nav-tab picker's "not shown"
// (addable) list while Z Mode was on — the picker could not offer it back
// once removed, or preview it as addable, purely because of the toggle. That
// special-casing is gone; Search is now just another tab, in both states.
//
// A bare NavPrefs (unopened Hive box) already answers `.tabs` with
// NavPrefs.defaultTabs, which includes Search — no state to probe with. So
// these tests give it a real, temp-dir-backed box and explicitly park Search
// off the bar first, which is the only configuration where the old exclusion
// was ever visible.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/settings/nav_tabs_screen.dart';

void main() {
  late Directory dir;
  late NavPrefs navPrefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nav_tabs_screen_test');
    Hive.init(dir.path);
    await NavPrefs.init();
    await ZModePrefs.init();
    navPrefs = NavPrefs();
    // Search parked off the bar — the "not shown" row is the only place the
    // old ZModePrefs.enabled special-case ever hid it.
    await navPrefs.setTabs(const [
      DockTab.home,
      DockTab.myList,
      DockTab.profile,
    ]);

    await sl.reset();
    sl.registerSingleton<NavPrefs>(navPrefs);
  });

  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Finder hiddenSearchRow() => find.byKey(const ValueKey('off_search'));

  testWidgets('Search is offered as addable with Z Mode off', (tester) async {
    expect(ZModePrefs.enabled, isFalse);
    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    expect(hiddenSearchRow(), findsOneWidget);
  });

  testWidgets('Search is offered as addable with Z Mode on', (tester) async {
    // See the module doc comment on watch_app's known Hive-in-testWidgets
    // hazard: a real write here needs a genuine event-loop turn, which the
    // pump-driven test binding never gives it on its own.
    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    expect(ZModePrefs.enabled, isTrue);

    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    expect(hiddenSearchRow(), findsOneWidget);
  });
}
