import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/home/home_screen.dart';
import 'package:watch_app/features/shell/dock_icons.dart';

/// The header download shortcut hides while Downloads sits on the dock —
/// same rule as [HomeSearchAction]: never offer it twice.
void main() {
  Future<void> pumpAction(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomeDownloadsAction())),
    );
  }

  Finder downloadIcon() => find.byWidgetPredicate(
    (w) => w is DockIcon && w.glyph == DockGlyph.download,
  );

  testWidgets('the download icon shows by default', (tester) async {
    await pumpAction(tester);
    expect(downloadIcon(), findsOneWidget);
  });

  testWidgets('hidden when Downloads is already a dock tab', (tester) async {
    final prefs = _DownloadsOnDockNavPrefs();
    await sl.reset();
    sl.registerSingleton<NavPrefs>(prefs);
    addTearDown(() async {
      await sl.reset();
    });

    await pumpAction(tester);
    expect(downloadIcon(), findsNothing);
  });
}

/// No Hive writes: the box-backed getter is bypassed so the test proves the
/// header reacts to the tab list, not the storage layer.
class _DownloadsOnDockNavPrefs extends NavPrefs {
  @override
  List<DockTab> get tabs => [DockTab.home, DockTab.downloads, DockTab.profile];
}
