import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/features/sources/aniyomi_recommended_repos.dart';
import 'package:watch_app/features/sources/aniyomi_repo_tab.dart';

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
    tempDir = await Directory.systemTemp.createTemp('aniyomi_repo_ui_test_');
    Hive.init(tempDir.path);
    await Hive.openBox<String>(kAniyomiReposBoxName);
    await Hive.openBox<dynamic>('aniyomi_installed');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  // Clear Hive box state between tests so each starts from a known baseline.
  setUp(() async {
    await Hive.box<String>(kAniyomiReposBoxName).clear();
    await Hive.box<dynamic>('aniyomi_installed').clear();
  });

  // ── AniyomiAddRepoDialog ──────────────────────────────────────────────────

  group('AniyomiAddRepoDialog', () {
    testWidgets('shows all recommended repo names', (tester) async {
      await tester.pumpWidget(_wrap(
        Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => showDialog<String>(
              context: ctx,
              builder: (_) => const AniyomiAddRepoDialog(),
            ),
            child: const Text('Open'),
          ),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Dialog title is visible.
      expect(find.text('Add Aniyomi repo'), findsOneWidget);

      // Every recommended repo name appears.
      for (final r in kRecommendedAniyomiRepos) {
        expect(find.text(r.name), findsOneWidget,
            reason: '${r.name} should appear in the dialog');
      }
    });

    testWidgets(
        'tapping recommended "Add" button pops dialog with the correct URL',
        (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: ctx,
                  builder: (_) => const AniyomiAddRepoDialog(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Tap the "Add" button on the first recommended repo.
      final addButtons = find.text('Add');
      expect(addButtons, findsWidgets);
      await tester.tap(addButtons.first);
      await tester.pumpAndSettle();

      expect(result, kRecommendedAniyomiRepos.first.url);
    });

    testWidgets('"Added" label shown when URL already in alreadyAddedUrls',
        (tester) async {
      await tester.pumpWidget(_wrap(
        Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => showDialog<String>(
              context: ctx,
              builder: (_) => AniyomiAddRepoDialog(
                alreadyAddedUrls: {kRecommendedAniyomiRepos.first.url},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Should show "Added" label, not an "Add" button for the first repo.
      expect(find.text('Added'), findsOneWidget);
    });
  });

  // ── AniyomiRepoTab ────────────────────────────────────────────────────────

  group('AniyomiRepoTab', () {
    testWidgets('shows EmptyState icon when no repos added', (tester) async {
      await tester.pumpWidget(_wrap(
        AniyomiRepoTab(
          repoUrls: const [],
          onRemoveRepo: (_) {},
        ),
      ));
      // One pump settles the static EmptyState widget tree without waiting
      // for any potentially long-running animation.
      await tester.pump();

      expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
    });

    testWidgets('calls installFn when Install button is tapped', (tester) async {
      const repoUrl = 'https://repo.example.com';
      bool installCalled = false;
      AniyomiRepoEntry? installedEntry;

      final fakeEntry = _fakeEntry('Fake Anime', 'com.fake.anime');

      Future<List<AniyomiRepoEntry>> fakeFetch(String url) async => [fakeEntry];
      Future<void> fakeInstall(AniyomiRepoEntry entry) async {
        installCalled = true;
        installedEntry = entry;
      }
      bool fakeInstalled(String pkg) => false;

      await tester.pumpWidget(_wrap(
        AniyomiRepoTab(
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
      expect(find.text('Fake Anime'), findsOneWidget);

      // The Install button should be visible.
      expect(find.text('Install'), findsOneWidget);

      // Tap it.
      await tester.tap(find.text('Install'));
      await tester.pump();  // kick off install
      await tester.pump();  // fakeInstall completes
      await tester.pump();  // setState rebuilds

      // installFn was invoked with the correct entry.
      expect(installCalled, isTrue);
      expect(installedEntry?.name, 'Fake Anime');
      expect(installedEntry?.pkg, 'com.fake.anime');
    });

    testWidgets(
        'calls uninstallFn when Installed button is tapped and confirmed',
        (tester) async {
      const repoUrl = 'https://repo.example.com';
      bool uninstallCalled = false;

      final fakeEntry = _fakeEntry('Fake Anime', 'com.fake.anime');

      Future<List<AniyomiRepoEntry>> fakeFetch(String url) async => [fakeEntry];
      Future<void> fakeUninstall(String pkg) async {
        uninstallCalled = true;
      }
      bool fakeInstalled(String pkg) => pkg == 'com.fake.anime';

      await tester.pumpWidget(_wrap(
        AniyomiRepoTab(
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
    });
  });
}
