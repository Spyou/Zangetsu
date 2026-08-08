import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_update.dart';
import 'package:watch_app/features/sources/mihon_repo_tab.dart';

/// Structural twin of `test/features/sources/aniyomi_repo_updates_test.dart`
/// — deliberately duplicated per spec Decision 3.

AniyomiRepoEntry _entry(String pkg, int code) => AniyomiRepoEntry(
      name: pkg, pkg: pkg, apk: '$pkg.apk', lang: 'en',
      version: '0.0.$code', code: code, nsfw: false, sources: const [],
      repoBaseUrl: 'https://r/x',
    );

void main() {
  testWidgets('badge + Update all appear after Check for updates', (t) async {
    final manager = MihonManager();

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: debugMihonRepoSection(
          url: 'https://r/x',
          manager: manager,
          fetchIndexFn: (_) async => [_entry('a', 21)],
          installedPkgsFn: (pkg) => pkg == 'a',
        ),
      ),
    ));
    await t.pumpAndSettle();

    // No updates yet: no badge, but the "Check for updates" action exists.
    expect(find.text('1 update'), findsNothing);
    expect(find.textContaining('Check for updates'), findsNothing);
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    expect(find.textContaining('Check for updates'), findsOneWidget);
    // Close the menu without selecting anything.
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();

    // Drive the manager to report one available update, then let the
    // AnimatedBuilder-wrapped badge react to the notifyListeners() call.
    manager.checkerOverride = (url, codes) async => [
          MihonUpdate(
            pkg: 'a',
            name: 'a',
            installedCode: 20,
            availableCode: 21,
            availableVersion: '0.0.21',
            entry: _entry('a', 21),
          ),
        ];
    await manager.checkRepoUpdates('https://r/x');
    await t.pump();

    // Header badge is always visible (no menu needed).
    expect(find.text('1 update'), findsOneWidget);

    // "Update all (N)" is a menu item, built lazily when the popup opens.
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    expect(find.textContaining('Update all'), findsOneWidget);
  });

  testWidgets('Update all clears the badge once the update is applied',
      (t) async {
    final manager = MihonManager();
    var applyCalls = 0;

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: debugMihonRepoSection(
          url: 'https://r/x',
          manager: manager,
          fetchIndexFn: (_) async => [_entry('a', 21)],
          installedPkgsFn: (pkg) => pkg == 'a',
          installFn: (entry) async {
            applyCalls++;
          },
        ),
      ),
    ));
    await t.pumpAndSettle();

    manager.checkerOverride = (url, codes) async => [
          MihonUpdate(
            pkg: 'a',
            name: 'a',
            installedCode: 20,
            availableCode: 21,
            availableVersion: '0.0.21',
            entry: _entry('a', 21),
          ),
        ];
    await manager.checkRepoUpdates('https://r/x');
    await t.pump();
    expect(find.text('1 update'), findsOneWidget);

    // Tap the badge itself to trigger _updateAll.
    await t.tap(find.text('1 update'));
    await t.pumpAndSettle();

    expect(applyCalls, 1);
    // The badge disappears once the pending update is cleared.
    expect(find.text('1 update'), findsNothing);
    expect(manager.updatesFor('https://r/x'), isEmpty);
  });
}
