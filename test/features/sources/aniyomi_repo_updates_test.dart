import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/aniyomi/aniyomi_update.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/features/sources/aniyomi_repo_tab.dart';

AniyomiRepoEntry _entry(String pkg, int code) => AniyomiRepoEntry(
      name: pkg, pkg: pkg, apk: '$pkg.apk', lang: 'en',
      version: '0.0.$code', code: code, nsfw: false, sources: const [],
      repoBaseUrl: 'https://r/x',
    );

void main() {
  testWidgets('badge + Update all appear after Check for updates', (t) async {
    final manager = AniyomiManager();

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: debugAniyomiRepoSection(
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
          AniyomiUpdate(
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
}
