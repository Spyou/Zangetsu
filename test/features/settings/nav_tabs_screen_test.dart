// Task 17 follow-up: Search is back as an opt-in dock tab. It lives in the
// Home header only while it is NOT on the bar — so the picker offers it as
// an addable row by default, and it must never be in the default dock.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/settings/nav_tabs_screen.dart';

class _MemoryNavPrefs extends NavPrefs {
  bool _keepDockExpanded = false;

  @override
  bool get keepDockExpanded => _keepDockExpanded;

  @override
  Future<void> setKeepDockExpanded(bool value) async {
    _keepDockExpanded = value;
    notifyListeners();
  }
}

void main() {
  late Directory dir;
  late NavPrefs navPrefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nav_tabs_screen_test');
    Hive.init(dir.path);
    await NavPrefs.init();
    await ZModePrefs.init();
    // On by default since the Settings toggle was removed; these tests cover
    // both paths, so start from off and let each one opt in.
    await ZModePrefs.setEnabled(false);
    navPrefs = _MemoryNavPrefs();

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

  testWidgets('Search is offered as an addable tab with Z Mode off', (
    tester,
  ) async {
    expect(ZModePrefs.enabled, isFalse);
    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();
    // The not-shown card sits below the fold in a lazy sliver — rows only
    // exist once scrolled to, same as the keep-dock switch below.
    await tester.scrollUntilVisible(
      notShownSearchRow(),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(notShownSearchRow(), findsOneWidget);
    expect(onBarSearchRow(), findsNothing);
  });

  testWidgets('Search is offered as an addable tab with Z Mode on', (
    tester,
  ) async {
    // See the module doc comment on watch_app's known Hive-in-testWidgets
    // hazard: a real write here needs a genuine event-loop turn, which the
    // pump-driven test binding never gives it on its own.
    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    expect(ZModePrefs.enabled, isTrue);

    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      notShownSearchRow(),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(notShownSearchRow(), findsOneWidget);
    expect(onBarSearchRow(), findsNothing);
  });

  testWidgets('Keep dock expanded is off by default and can be enabled', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NavTabsScreen()));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('keep-dock-expanded-switch'));
    await tester.scrollUntilVisible(
      toggle,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(find.text('Keep navigation expanded'));
    await tester.pump();

    expect(tester.widget<Switch>(toggle).value, isTrue);
  });
}
