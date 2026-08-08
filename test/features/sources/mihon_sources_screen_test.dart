// Task M8b: the dedicated Mihon (manga) ecosystem screen — structural twin
// of AniyomiSourcesScreen's phone view. No test exists yet for the Aniyomi
// screen this mirrors (`aniyomi_sources_screen.dart`), so this file follows
// the closest established patterns instead: `test/mihon/mihon_repo_tab_test.dart`
// (Hive setup for the repo box) and `test/features/sources/ani_source_row_update_test.dart`
// (the debug-row update-button seam).
//
// Deliberately does NOT pre-seed a repo URL before pumping the Repositories
// tab: MihonRepoTab kicks off a real (unmocked) `MihonRepo.fetchIndex`
// network call as soon as it has a non-empty repoUrls list, and this screen
// (like its Aniyomi twin) doesn't inject a fetchIndexFn seam — so a
// pre-seeded URL would leave a live network Future in flight with no way to
// resolve it deterministically. MihonRepoTab's fetch/install/uninstall logic
// itself is already covered by mihon_repo_tab_test.dart with injected seams;
// this file only covers what's new here: the screen's own plumbing (Hive
// repo-box ownership, the Installed tab, and the FAB → dialog wiring).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_update.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/mihon_repo_tab.dart';
import 'package:watch_app/features/sources/mihon_sources_screen.dart';

MihonProvider _prov({
  int id = 1,
  String pkg = 'p.manga',
  String name = 'MangaSrc',
  String lang = 'en',
}) =>
    MihonProvider(
      info: MihonSourceInfo(
        id: id,
        name: name,
        lang: lang,
        baseUrl: '',
        pkg: pkg,
        nsfw: false,
        version: '1.0',
        versionCode: 1,
      ),
    );

MihonUpdate _upd() => MihonUpdate(
      pkg: 'p.manga',
      name: 'MangaSrc',
      installedCode: 1,
      availableCode: 2,
      availableVersion: '2.0',
      entry: AniyomiRepoEntry(
        name: 'MangaSrc',
        pkg: 'p.manga',
        apk: 'x.apk',
        lang: 'en',
        version: '2.0',
        code: 2,
        nsfw: false,
        sources: const [],
        repoBaseUrl: 'https://r/x',
      ),
    );

void main() {
  final sl = GetIt.instance;

  group('MihonSourcesScreen', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir =
          await Directory.systemTemp.createTemp('mihon_sources_screen_test_');
      Hive.init(tempDir.path);
      await Hive.openBox<String>(kMihonReposBoxName);
      await Hive.openBox<dynamic>(MihonExtensionService.installedBoxName);
    });

    tearDownAll(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    setUp(() async {
      await Hive.box<String>(kMihonReposBoxName).clear();
      await Hive.box<dynamic>(MihonExtensionService.installedBoxName).clear();
      sl.registerSingleton<MihonManager>(MihonManager());
    });

    tearDown(() async => sl.reset());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider(
            create: (_) => ActiveSourceCubit(),
            child: const MihonSourcesScreen(),
          ),
        ),
      );
      // Bounded pumps, not pumpAndSettle: with repoUrls empty this settles
      // fine, but the whole point of this helper is to stay safe even if a
      // future edit adds a repo — see the file-level note on the network
      // hazard above.
      await tester.pump();
      await tester.pump();
    }

    testWidgets('titles the screen Mihon with Installed/Repositories tabs',
        (tester) async {
      await pump(tester);

      expect(find.text('Mihon'), findsOneWidget);
      expect(find.text('Installed'), findsOneWidget);
      expect(find.text('Repositories'), findsOneWidget);
    });

    testWidgets('shows the manga-specific empty state when nothing installed',
        (tester) async {
      await pump(tester);

      expect(find.text('No Mihon sources installed.'), findsOneWidget);
    });

    testWidgets(
        'lists a registered source with mihon vocabulary and lets you '
        'set it active', (tester) async {
      sl<MihonManager>().register(_prov());
      await pump(tester);

      expect(find.text('MangaSrc'), findsOneWidget);
      expect(find.text('mihon • en'), findsOneWidget);

      await tester.tap(find.text('MangaSrc'));
      await tester.pump();

      expect(find.text('Active source: MangaSrc'), findsOneWidget);
    });

    testWidgets('uninstall removes the source from MihonManager',
        (tester) async {
      sl<MihonManager>().register(_prov());
      await pump(tester);
      expect(sl<MihonManager>().all, hasLength(1));

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      // Confirm dialog.
      await tester.tap(find.text('Uninstall').last);
      await tester.pumpAndSettle();

      expect(sl<MihonManager>().all, isEmpty);
      expect(find.text('No Mihon sources installed.'), findsOneWidget);
    });

    testWidgets(
        'Repositories tab shows the manga-specific empty state with no repos',
        (tester) async {
      await pump(tester);

      await tester.tap(find.text('Repositories'));
      // The tab swipe is a plain (non-network, non-spinner) animation here —
      // repoUrls is empty, so MihonRepoTab renders a static EmptyState with
      // nothing in flight. Safe to fully settle.
      await tester.pumpAndSettle();

      expect(find.textContaining('No Mihon repos added yet'), findsOneWidget);
    });

    testWidgets('the FAB opens the Mihon add-repo dialog', (tester) async {
      await pump(tester);

      await tester.tap(find.text('Repositories'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.byType(MihonAddRepoDialog), findsOneWidget);
    });
  });

  // ── Update button (debug seam), mirrors ani_source_row_update_test.dart ──
  group('debugMihonSourceRow', () {
    Widget host(Widget child) => MaterialApp(
          home: BlocProvider(
            create: (_) => ActiveSourceCubit(),
            child: Scaffold(body: child),
          ),
        );

    testWidgets('no Update button when there is no update', (t) async {
      await t.pumpWidget(host(debugMihonSourceRow(
        source: _prov(),
        activeId: 'mihon:1',
        updateLookupFn: (_) => null,
      )));
      expect(find.textContaining('Update'), findsNothing);
    });

    testWidgets('shows Update button and applies on tap', (t) async {
      var applied = false;
      await t.pumpWidget(host(debugMihonSourceRow(
        source: _prov(),
        activeId: 'mihon:1',
        updateLookupFn: (pkg) => pkg == 'p.manga' ? _upd() : null,
        applyUpdateFn: (u) async => applied = true,
      )));
      expect(find.text('Update → v2.0'), findsOneWidget);
      await t.tap(find.text('Update → v2.0'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(applied, isTrue);
    });
  });
}
