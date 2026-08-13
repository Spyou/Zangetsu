// Task 2 (+ user-added-repos follow-up, + Installed/Repositories tabs):
// LnReaderSourcesScreen — browse user-added LNReader novel-source repos,
// install/uninstall, now structured as Installed/Repositories tabs (mirrors
// MihonSourcesScreen's TabBar shell).
//
// Uses an IN-MEMORY fake LnReaderExtensionService (not the real Hive-backed
// one) for plugin install state AND catalog fetches: a real box does file I/O
// that never resolves under the fake-async widget-test zone, so the screen's
// in-flight CircularProgressIndicator (an infinite animation) never clears
// and pumpAndSettle hangs. The fake completes synchronously, so bounded
// `pump()`s suffice. We never pumpAndSettle (the row spinner + SnackBar would
// never settle); a trailing multi-second pump drains the SnackBar's
// auto-dismiss timer so nothing is pending at teardown.
//
// The `lnreader_repos` box (just a list of URL strings, no plugin content) IS
// real Hive — same reasoning `mihon_repo_tab_test.dart` uses for
// `kMihonReposBoxName`. UNLIKE that file, though, this screen owns the box
// directly (no injectable `repoUrls` seam), so every test that adds/removes a
// tracked repo makes a REAL write during the test body. A bare `await` on
// that write never resolves under this file's fake-async zone — its
// completion microtask lands in the fake zone's queue, which nothing here
// ever flushes — so every DIRECT real box operation the test body itself
// makes (seeding a URL via [seedRepo], the final Hive.close()/tempDir
// teardown) runs inside `tester.runAsync`, which forwards scheduling to the
// real event loop instead of the frozen fake one.
//
// That covers writes the test body makes itself. It does NOT cover writes
// the *screen* makes from inside its own tap handlers (`_addRepo`,
// `_removeRepo`, both real `lnreader_repos` box I/O) — tapping the FAB's Add
// button or a repo's remove-confirm. Wrapping the tap (plus draining it, via
// either bounded pumps or a genuine `Future.delayed`, both tried) in
// `tester.runAsync` too *looks* like the same fix and the write genuinely
// does complete (confirmed by reading the box right after), but it leaves
// Hive's internal per-box write queue (`ReadWriteSync`, in the `hive`
// package) in a state that deadlocks `Hive.close()` in `tearDownAll` —
// confirmed by isolating it to exactly that combination: two direct
// `tester.runAsync` writes back-to-back in one test, fine; one *tap-driven*
// write via `tester.runAsync` behind a confirmation dialog, anywhere earlier
// in the file, and `Hive.close()` never returns (even wrapped in its own
// `runAsync`, as `tearDownAll` does below). So this file never taps a
// control whose handler performs a real Hive write: dialog/button *wiring*
// (does tapping Add pop the dialog with the typed URL?) is tested against
// `LnReaderAddRepoDialog` standalone, the same way `mihon_repo_tab_test.dart`
// tests `MihonAddRepoDialog`; the resulting *persistence* (does the box end
// up with/without the URL, does the screen re-render from it?) is driven
// with a direct `tester.runAsync` write, exactly like [seedRepo] — never
// through the real button.
//
// Dropped from the previous (single-scroll) version of this file, with a
// reason each:
// - The pull-to-refresh RefreshIndicator test: not part of the required
//   coverage here, and the code path it guarded (`_load(refresh: true)`) is
//   untouched by the tab restructure — narrowing scope rather than
//   re-deriving a tab-aware version of its Completer-gated dance.
// - The "orphaned installed plugin shows inline" test: that concept doesn't
//   exist anymore — the Installed tab now always lists every installed
//   plugin, tracked-repo or not, so there's nothing "orphaned" left to
//   special-case.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/lnreader/novel_lang_prefs.dart';
import 'package:watch_app/features/sources/lnreader_sources_screen.dart';

const _repoUrl = 'https://repo.test/plugins.min.json';

const _catalog = <LnReaderPluginMeta>[
  LnReaderPluginMeta(
    id: 'plugin-a',
    name: 'Plugin A',
    site: 'https://a.test/',
    lang: 'en',
    version: '1.0.0',
    url: 'https://cdn.test/a.js',
    iconUrl: 'https://cdn.test/a.png',
  ),
  LnReaderPluginMeta(
    id: 'plugin-b',
    name: 'Plugin B',
    site: 'https://b.test/',
    lang: 'id',
    version: '2.0.0',
    url: 'https://cdn.test/b.js',
    iconUrl: 'https://cdn.test/b.png',
  ),
];

class _FakeLnrService extends LnReaderExtensionService {
  _FakeLnrService() : super(httpGet: (_) async => '');
  final Map<String, LnReaderPluginMeta> _installed = {};

  /// url -> catalog, populated per test. A url with no entry here fetches as
  /// an empty catalog (never throws) unless [errorUrls] says otherwise.
  final Map<String, List<LnReaderPluginMeta>> catalogs = {};
  final Set<String> errorUrls = {};

  @override
  Future<List<LnReaderPluginMeta>> fetchIndex(String indexUrl) async {
    if (errorUrls.contains(indexUrl)) throw StateError('repo unreachable');
    return catalogs[indexUrl] ?? const [];
  }

  @override
  Future<void> install(LnReaderPluginMeta meta) async => _installed[meta.id] = meta;
  @override
  List<LnReaderPluginMeta> installed() => _installed.values.toList();
  @override
  Future<void> uninstall(String id) async => _installed.remove(id);
  @override
  String? jsFor(String id) => _installed.containsKey(id) ? '/*js*/' : null;
}

/// Spy on top of the real [LnReaderManager] — delegates to it (so state still
/// clears the way the fake service expects) but records `uninstall` calls, so
/// a Remove test can prove the row routes through the manager rather than
/// calling `LnReaderExtensionService.uninstall` directly.
class _SpyLnReaderManager extends LnReaderManager {
  _SpyLnReaderManager({required super.service, required super.fetch});
  final List<String> uninstallCalls = [];

  @override
  Future<void> uninstall(String pluginId) async {
    uninstallCalls.add(pluginId);
    await super.uninstall(pluginId);
  }
}

/// In-memory [NovelLangPrefs] so this test needs no real Hive box (a real box
/// does file I/O that never resolves under this file's fake-async zone — see
/// the header note).
class _FakeNovelLangPrefs extends NovelLangPrefs {
  _FakeNovelLangPrefs([this._langs]);
  Set<String>? _langs;
  @override
  Set<String>? get enabled => _langs;
  @override
  Future<void> setEnabled(Set<String> langs) async {
    _langs = langs;
    notifyListeners();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeLnrService service;
  late _SpyLnReaderManager manager;

  // Hive is initialised once for all tests in this file (real, but only the
  // plain `lnreader_repos` Box<String> ever touches it); cleared between
  // tests via box.clear(), same convention `mihon_repo_tab_test.dart` uses.
  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('lnreader_sources_screen_test_');
    Hive.init(tempDir.path);
    await Hive.openBox<String>(kLnReaderReposBoxName);
  });

  tearDownAll(() async {
    // Real disk I/O, run through the binding's real-zone escape hatch — see
    // the file header. No `tester` exists at this scope, but `runAsync` is a
    // binding method, not a `WidgetTester` one; `WidgetTester.runAsync` is
    // just a thin forward to this same call.
    await binding.runAsync(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });
  });

  setUp(() async {
    // Awaited (setUp runs outside any testWidgets fake-async zone, so this is
    // a normal real await) — left un-awaited, the real disk clear can still
    // be in flight when the next test starts, and its eventual completion
    // can land after that test's own seeded add, silently wiping it.
    await Hive.box<String>(kLnReaderReposBoxName).clear();
    service = _FakeLnrService();
    manager = _SpyLnReaderManager(
      service: service,
      fetch: (url, init) async => throw StateError(
        'fetch should not be called — the screen never loads the runtime',
      ),
    );
    sl.registerSingleton<LnReaderExtensionService>(service);
    sl.registerSingleton<LnReaderManager>(manager);
    // Both catalog languages on, so the non-language tests see both plugins.
    sl.registerSingleton<NovelLangPrefs>(_FakeNovelLangPrefs({'en', 'id'}));
  });

  tearDown(() async => sl.reset());

  /// Seeds the (real) repo box with [url] before the screen mounts. Run
  /// through `tester.runAsync` — see the file header for why a bare `await`
  /// on a real Hive write hangs under this file's fake-async zone.
  Future<void> seedRepo(WidgetTester tester, String url) =>
      tester.runAsync(() => Hive.box<String>(kLnReaderReposBoxName).add(url));

  // Bounded pumps — never pumpAndSettle (see file header).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // Drain the SnackBar auto-dismiss timer so nothing is pending at teardown.
  Future<void> drainSnackBars(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  Future<void> loadScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LnReaderSourcesScreen()));
    await settle(tester);
  }

  // Switches tabs by label ('Installed' or 'Repositories') — plain tap, no
  // Hive involved. The default tab (index 0) is Installed. TabController's
  // switch animation is `kTabScrollDuration` (300ms) — settle() alone (250ms)
  // isn't quite enough, so pad past it or a tap right after can land on the
  // still-animating TabBarView page and miss its target.
  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 150));
  }

  group('LnReaderSourcesScreen — Installed tab', () {
    testWidgets('shows the empty state when nothing is installed',
        (tester) async {
      await loadScreen(tester);

      expect(find.text('No sources installed yet.'), findsOneWidget);
    });

    testWidgets(
        'lists an installed plugin with Remove, routing through LnReaderManager',
        (tester) async {
      await service.install(_catalog[0]);
      await loadScreen(tester);

      expect(find.text('Plugin A'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await settle(tester);

      expect(manager.uninstallCalls, ['plugin-a']);
      expect(service.installed(), isEmpty);
      expect(find.text('No sources installed yet.'), findsOneWidget);
      await drainSnackBars(tester);
    });
  });

  group('LnReaderSourcesScreen — Repositories tab, no repos', () {
    testWidgets('shows the empty state and the Add-repository FAB',
        (tester) async {
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');

      expect(find.textContaining('No repositories added'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  group('LnReaderSourcesScreen — Repositories tab, with a repo', () {
    testWidgets("lists a tracked repo's catalog entries with Install",
        (tester) async {
      service.catalogs[_repoUrl] = _catalog;
      await seedRepo(tester, _repoUrl);
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');

      expect(find.text('Plugin A'), findsOneWidget);
      expect(find.text('Plugin B'), findsOneWidget);
      expect(find.text('en · a.test'), findsOneWidget);
      expect(find.text('id · b.test'), findsOneWidget);
      expect(find.text('Install'), findsNWidgets(2));
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    });

    testWidgets(
        'tapping Install installs the plugin, flips the row to Remove, and '
        'Remove routes back through LnReaderManager', (tester) async {
      service.catalogs[_repoUrl] = _catalog;
      await seedRepo(tester, _repoUrl);
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');
      expect(service.installed(), isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Install').first);
      await settle(tester);

      expect(service.installed().map((m) => m.id), contains('plugin-a'));
      // In a repo's catalog an installed source flips to an "Uninstall" text
      // button (not the Installed tab's trash icon), matching Mihon's repo tab.
      expect(find.widgetWithText(OutlinedButton, 'Uninstall'), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);
      await drainSnackBars(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Uninstall'));
      await settle(tester);

      expect(manager.uninstallCalls, ['plugin-a']);
      expect(service.installed(), isEmpty);
      expect(find.text('Install'), findsNWidgets(2));
      await drainSnackBars(tester);
    });

    testWidgets('a search query filters the list down to matching rows',
        (tester) async {
      service.catalogs[_repoUrl] = _catalog;
      await seedRepo(tester, _repoUrl);
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');

      await tester.enterText(find.byType(TextField), 'Plugin B');
      await settle(tester);

      // Assert on the row subtitle (unique) — 'Plugin B' alone would also match
      // the query text now sitting in the TextField.
      expect(find.text('id · b.test'), findsOneWidget); // Plugin B row shown
      expect(find.text('en · a.test'), findsNothing); // Plugin A row filtered
    });

    testWidgets('the language filter hides sources of unselected languages',
        (tester) async {
      service.catalogs[_repoUrl] = _catalog;
      await seedRepo(tester, _repoUrl);
      await sl<NovelLangPrefs>().setEnabled({'en'}); // Indonesian off
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');

      expect(find.text('en · a.test'), findsOneWidget); // English shown
      expect(find.text('id · b.test'), findsNothing); // Indonesian hidden
    });

    testWidgets('a repo that fails to fetch shows a failure message, not a crash',
        (tester) async {
      service.errorUrls.add(_repoUrl);
      await seedRepo(tester, _repoUrl);
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');

      // The repo header's caption also reads "Failed to load" (no colon) —
      // match the colon-suffixed detail line so this stays unambiguous.
      expect(find.textContaining('Failed to load:'), findsOneWidget);
    });
  });

  group('LnReaderSourcesScreen — managing repos', () {
    testWidgets('the FAB opens the add-repo dialog', (tester) async {
      service.catalogs[_repoUrl] = _catalog;
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');
      expect(find.textContaining('No repositories added'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);

      expect(find.byType(LnReaderAddRepoDialog), findsOneWidget);
      // Never taps 'Add' from here on out — see the file header: that would
      // route through the screen's own `_addRepo`, a real Hive write
      // triggered from inside a tap handler.
    });

    // Standalone twin of `MihonAddRepoDialog`'s own test in
    // mihon_repo_tab_test.dart — proves the dialog's submit wiring without
    // ever mounting LnReaderSourcesScreen (so no real Hive write happens).
    // What the returned URL actually does once `_addRepo` persists and
    // reloads it is covered separately by "lists a tracked repo's catalog
    // entries with Install" above, seeded directly via [seedRepo].
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
                  builder: (_) => const LnReaderAddRepoDialog(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), _repoUrl);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(result, _repoUrl);
    });

    testWidgets(
        'removing a repo drops it from the box; an already-installed plugin '
        'from it stays installed and shows up under the Installed tab',
        (tester) async {
      service.catalogs[_repoUrl] = _catalog;
      await seedRepo(tester, _repoUrl);
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');
      await tester.tap(find.widgetWithText(FilledButton, 'Install').first);
      await settle(tester);
      await drainSnackBars(tester);

      // Confirm-dialog wiring: the 3-dot menu's "Remove repository" item
      // surfaces the "Remove repo?" confirmation. Dismiss with Cancel rather
      // than tapping through to its own Remove button — that routes to the
      // screen's own `_removeRepo`, the same real-Hive-write-from-a-tap-
      // handler hazard the file header describes, confirmed for this exact
      // dialog by direct repro (both a `runAsync`-wrapped tap+pump and a
      // `runAsync`-wrapped tap+`Future.delayed`, the pattern
      // `mode_switcher_test.dart` uses for a simpler fire-and-forget write,
      // still deadlock `Hive.close()` once a dialog route is in the mix).
      // The resulting persistence step is driven directly below instead, the
      // same way [seedRepo] does the add.
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300)); // popup route open
      await tester.tap(find.text('Remove repository'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300)); // dialog route open
      expect(find.text('Remove repo?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      await tester.runAsync(() => Hive.box<String>(kLnReaderReposBoxName).clear());
      // Force an actual unmount before remounting: pumping the identical
      // MaterialApp(home: LnReaderSourcesScreen()) tree a second time keeps
      // the same State (Flutter reconciles rather than rebuilding), so
      // `_load()` never re-runs and the screen keeps showing the pre-clear
      // catalog. A throwaway widget in between forces a real dispose+
      // initState cycle, same as `_load(refresh: true)` reacting to a real
      // repo removal would.
      await tester.pumpWidget(const SizedBox.shrink());
      await loadScreen(tester);
      await tapTab(tester, 'Repositories');

      expect(Hive.box<String>(kLnReaderReposBoxName).values, isEmpty);
      expect(service.installed().map((m) => m.id), contains('plugin-a'));
      expect(find.textContaining('No repositories added'), findsOneWidget);

      await tapTab(tester, 'Installed');
      expect(find.text('Plugin A'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    });
  });
}
