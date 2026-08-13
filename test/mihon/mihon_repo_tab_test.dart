import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';
import 'package:watch_app/features/sources/mihon_repo_tab.dart';

/// Widget tests for the Mihon repo add/browse/install UI. Structural twin of
/// `test/aniyomi/aniyomi_repo_ui_test.dart` — deliberately duplicated per
/// spec Decision 3, not shared with the anime test.

/// Wraps [child] in a minimal MaterialApp+Scaffold suitable for widget tests.
Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

AniyomiRepoEntry _fakeEntry(String name, String pkg) => AniyomiRepoEntry(
      name: name,
      pkg: pkg,
      apk: '$pkg-v1.apk',
      lang: 'en',
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: [],
      repoBaseUrl: 'https://repo.example.com',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  // Hive is initialised once for all tests in this file; boxes are cleared
  // between tests via box.clear(). This avoids repeated close+reinit cycles
  // which can hang on some macOS CI configurations.
  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('mihon_repo_ui_test_');
    Hive.init(tempDir.path);
    await Hive.openBox<String>(kMihonReposBoxName);
    await Hive.openBox<dynamic>(MihonExtensionService.installedBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  // Clear Hive box state between tests so each starts from a known baseline.
  setUp(() async {
    await Hive.box<String>(kMihonReposBoxName).clear();
    await Hive.box<dynamic>(MihonExtensionService.installedBoxName).clear();
  });

  // ── MihonAddRepoDialog ──────────────────────────────────────────────────

  group('MihonAddRepoDialog', () {
    testWidgets('typing a URL and tapping Add pops the dialog with that URL',
        (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: ctx,
                  builder: (_) => const MihonAddRepoDialog(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        'https://example.com/my-repo',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(result, 'https://example.com/my-repo');
    });

    testWidgets('does not render a RECOMMENDED section', (tester) async {
      await tester.pumpWidget(_wrap(
        Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => showDialog<String>(
              context: ctx,
              builder: (_) => const MihonAddRepoDialog(),
            ),
            child: const Text('Open'),
          ),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Add Mihon repo'), findsOneWidget);
      expect(find.text('RECOMMENDED'), findsNothing);
    });
  });

  // ── MihonRepoTab ────────────────────────────────────────────────────────

  group('MihonRepoTab', () {
    testWidgets('shows EmptyState icon and manga-specific copy when no repos '
        'added', (tester) async {
      await tester.pumpWidget(_wrap(
        MihonRepoTab(
          repoUrls: const [],
          onRemoveRepo: (_) {},
        ),
      ));
      // One pump settles the static EmptyState widget tree without waiting
      // for any potentially long-running animation.
      await tester.pump();

      expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
      expect(find.textContaining('No Mihon repos added yet'), findsOneWidget);
    });

    testWidgets('renders a failed-fetch repo as an error state, not a crash',
        (tester) async {
      const repoUrl = 'https://repo.example.com';

      Future<List<AniyomiRepoEntry>> failingFetch(String url) async {
        throw Exception('network unreachable');
      }

      await tester.pumpWidget(_wrap(
        MihonRepoTab(
          repoUrls: const [repoUrl],
          onRemoveRepo: (_) {},
          fetchIndexFn: failingFetch,
          installedPkgsFn: (_) => false,
        ),
      ));

      await tester.pump(); // initState kicks off _fetchCatalog
      await tester.pump(); // the throwing future completes
      await tester.pump(); // setState rebuilds with the error

      expect(find.text('Failed to load'), findsOneWidget);
      expect(find.textContaining('network unreachable'), findsOneWidget);
      // No install/uninstall row should render for a repo that never loaded.
      expect(find.text('Install'), findsNothing);
    });

    testWidgets('renders empty-index repo with the no-extensions message',
        (tester) async {
      const repoUrl = 'https://repo.example.com';

      await tester.pumpWidget(_wrap(
        MihonRepoTab(
          repoUrls: const [repoUrl],
          onRemoveRepo: (_) {},
          fetchIndexFn: (_) async => const [],
          installedPkgsFn: (_) => false,
        ),
      ));

      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('No extensions found in this repo.'), findsOneWidget);
    });

    testWidgets('calls installFn when Install button is tapped', (tester) async {
      const repoUrl = 'https://repo.example.com';
      bool installCalled = false;
      AniyomiRepoEntry? installedEntry;

      final fakeEntry = _fakeEntry('Fake Manga', 'com.fake.manga');

      Future<List<AniyomiRepoEntry>> fakeFetch(String url) async => [fakeEntry];
      Future<void> fakeInstall(AniyomiRepoEntry entry) async {
        installCalled = true;
        installedEntry = entry;
      }
      bool fakeInstalled(String pkg) => false;

      await tester.pumpWidget(_wrap(
        MihonRepoTab(
          repoUrls: const [repoUrl],
          onRemoveRepo: (_) {},
          fetchIndexFn: fakeFetch,
          installFn: fakeInstall,
          installedPkgsFn: fakeInstalled,
        ),
      ));

      // Wait for the async fetchIndexFn to complete and the list to render.
      await tester.pump();          // trigger initState → _fetchCatalog starts
      await tester.pump();          // fakeFetch completes (returns immediately)
      await tester.pump();          // setState rebuilds UI

      // The extension name should be visible after fetch completes.
      expect(find.text('Fake Manga'), findsOneWidget);

      // The Install button should be visible.
      expect(find.text('Install'), findsOneWidget);

      // Tap it.
      await tester.tap(find.text('Install'));
      await tester.pump();  // kick off install
      await tester.pump();  // fakeInstall completes
      await tester.pump();  // setState rebuilds

      // installFn was invoked with the correct entry.
      expect(installCalled, isTrue);
      expect(installedEntry?.name, 'Fake Manga');
      expect(installedEntry?.pkg, 'com.fake.manga');
    });

    // keiyoushi's real index has 1,369 extensions. The list used to be an
    // eager Column, i.e. ~2,700 widgets built in one frame the moment the
    // section expanded.
    testWidgets('builds only the on-screen rows for a keiyoushi-sized repo',
        (tester) async {
      final many = [
        for (var i = 0; i < 1369; i++) _fakeEntry('Manga $i', 'com.fake.m$i'),
      ];

      await tester.pumpWidget(_wrap(
        MihonRepoTab(
          repoUrls: const ['https://repo.example.com'],
          onRemoveRepo: (_) {},
          fetchIndexFn: (_) async => many,
          installedPkgsFn: (_) => false,
        ),
      ));

      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // AnimatedSize

      // The first rows are real and interactive…
      expect(find.text('Manga 0'), findsOneWidget);
      final builtRows = tester.widgetList(find.text('Install')).length;
      expect(builtRows, greaterThan(0));
      // …but the other ~1,350 were never built.
      expect(
        builtRows,
        lessThan(100),
        reason: 'expected a virtualized list, got $builtRows of 1369 rows',
      );

      // Rows further down are reachable by scrolling.
      await tester.drag(find.text('Manga 0'), const Offset(0, -1500));
      await tester.pump();
      expect(find.text('Manga 0'), findsNothing);
      expect(find.textContaining('Manga '), findsWidgets);
    });

    testWidgets(
        'calls uninstallFn when Installed button is tapped and confirmed',
        (tester) async {
      const repoUrl = 'https://repo.example.com';
      bool uninstallCalled = false;
      String? uninstalledPkg;

      final fakeEntry = _fakeEntry('Fake Manga', 'com.fake.manga');

      Future<List<AniyomiRepoEntry>> fakeFetch(String url) async => [fakeEntry];
      Future<void> fakeUninstall(String pkg) async {
        uninstallCalled = true;
        uninstalledPkg = pkg;
      }
      bool fakeInstalled(String pkg) => pkg == 'com.fake.manga';

      await tester.pumpWidget(_wrap(
        MihonRepoTab(
          repoUrls: const [repoUrl],
          onRemoveRepo: (_) {},
          fetchIndexFn: fakeFetch,
          uninstallFn: fakeUninstall,
          installedPkgsFn: fakeInstalled,
        ),
      ));

      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Installed'), findsOneWidget);

      // Tap "Installed" to trigger uninstall confirm dialog.
      await tester.tap(find.text('Installed'));
      await tester.pumpAndSettle();

      // Dialog appears.
      expect(find.text('Uninstall'), findsWidgets);

      // Confirm — tap the last "Uninstall" text (dialog action button).
      await tester.tap(find.text('Uninstall').last);
      await tester.pumpAndSettle();

      expect(uninstallCalled, isTrue);
      expect(uninstalledPkg, 'com.fake.manga');
    });
  });
}
