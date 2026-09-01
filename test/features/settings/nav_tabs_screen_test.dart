// Task 17: Search left the dock for good — it lives in the Home header now
// (HomeSearchAction, beside the sources icon) — and DockTab.search was
// removed from the enum entirely, so nothing offers it here any more, in
// either Z Mode state.
//
// This file used to prove the opposite: that Search WAS offered as an
// addable "not shown" row once Z Mode's old exclusion was lifted (task 11).
// That enum member is gone, so those old assertions don't even compile any
// more — rewritten to prove Search is absent from both the on-bar preview
// and the "not shown" addable list.

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

    await sl.reset();
    sl.registerSingleton<NavPrefs>(navPrefs);
  });

  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Finder notShownSearchRow() => find.byKey(const ValueKey('off_search'));
  Finder onBarSearchRow() => find.byKey(const ValueKey('on_search'));

  testWidgets('Search is not offered anywhere with Z Mode off', (
    tester,
  ) async {
    expect(ZModePrefs.enabled, isFalse);
    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    expect(notShownSearchRow(), findsNothing);
    expect(onBarSearchRow(), findsNothing);
  });

  testWidgets('Search is not offered anywhere with Z Mode on', (
    tester,
  ) async {
    // See the module doc comment on watch_app's known Hive-in-testWidgets
    // hazard: a real write here needs a genuine event-loop turn, which the
    // pump-driven test binding never gives it on its own.
    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    expect(ZModePrefs.enabled, isTrue);

    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    expect(notShownSearchRow(), findsNothing);
    expect(onBarSearchRow(), findsNothing);
  });
}
