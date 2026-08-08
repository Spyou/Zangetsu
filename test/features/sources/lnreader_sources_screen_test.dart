// Task 2: LnReaderSourcesScreen — browse the LNReader novel-source catalog and
// install/uninstall.
//
// Uses an IN-MEMORY fake LnReaderExtensionService (not the real Hive-backed
// one): a real box does file I/O that never resolves under the fake-async
// widget-test zone, so the screen's in-flight CircularProgressIndicator (an
// infinite animation) never clears and pumpAndSettle hangs. The fake completes
// synchronously, so bounded `pump()`s suffice. We never pumpAndSettle (the row
// spinner + SnackBar would never settle); a trailing multi-second pump drains
// the SnackBar's auto-dismiss timer so nothing is pending at teardown.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/features/sources/lnreader_sources_screen.dart';

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

  /// When set, [fetchIndex] awaits this instead of resolving immediately —
  /// lets a test hold a refresh "in flight" to inspect the widget tree
  /// mid-load without a real, unbounded delay.
  Completer<List<LnReaderPluginMeta>>? fetchGate;

  @override
  Future<List<LnReaderPluginMeta>> fetchIndex() async =>
      fetchGate != null ? fetchGate!.future : _catalog;
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
/// the Remove test can prove the row routes through the manager rather than
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLnrService service;
  late _SpyLnReaderManager manager;

  setUp(() {
    service = _FakeLnrService();
    manager = _SpyLnReaderManager(
      service: service,
      fetch: (url, init) async => throw StateError(
        'fetch should not be called — the screen never loads the runtime',
      ),
    );
    sl.registerSingleton<LnReaderExtensionService>(service);
    sl.registerSingleton<LnReaderManager>(manager);
  });

  tearDown(() async => sl.reset());

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

  group('LnReaderSourcesScreen', () {
    testWidgets('lists catalog entries with an Install affordance', (tester) async {
      await loadScreen(tester);

      expect(find.text('Plugin A'), findsOneWidget);
      expect(find.text('Plugin B'), findsOneWidget);
      expect(find.text('en · a.test'), findsOneWidget);
      expect(find.text('id · b.test'), findsOneWidget);
      expect(find.text('Install'), findsNWidgets(2));
      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('tapping Install installs the plugin and flips the row to Remove',
        (tester) async {
      await loadScreen(tester);
      expect(service.installed(), isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Install').first);
      await settle(tester);

      expect(service.installed().map((m) => m.id), contains('plugin-a'));
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);
      await drainSnackBars(tester);
    });

    testWidgets('a search query filters the list down to matching rows',
        (tester) async {
      await loadScreen(tester);

      await tester.enterText(find.byType(TextField), 'Plugin B');
      await settle(tester);

      // Assert on the row subtitle (unique) — 'Plugin B' alone would also match
      // the query text now sitting in the TextField.
      expect(find.text('id · b.test'), findsOneWidget); // Plugin B row shown
      expect(find.text('en · a.test'), findsNothing); // Plugin A row filtered
    });

    testWidgets('Remove routes through LnReaderManager.uninstall and clears the row',
        (tester) async {
      await loadScreen(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Install').first);
      await settle(tester);
      expect(service.installed(), hasLength(1));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Remove'));
      await settle(tester);

      expect(manager.uninstallCalls, ['plugin-a']);
      expect(service.installed(), isEmpty);
      expect(find.text('Install'), findsNWidgets(2));
      await drainSnackBars(tester);
    });

    testWidgets(
        'pull-to-refresh keeps the RefreshIndicator + list mounted instead of '
        'swapping to a full-page spinner', (tester) async {
      await loadScreen(tester);
      expect(find.text('Plugin A'), findsOneWidget);

      // Hold fetchIndex() open so the refresh is still in flight when we
      // inspect the tree.
      service.fetchGate = Completer<List<LnReaderPluginMeta>>();

      final refreshState =
          tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator));
      // Fire-and-forget, per RefreshIndicator's own test suite convention —
      // its future only resolves once the gate below completes, and we stick
      // to bounded pumps rather than awaiting it directly.
      unawaited(refreshState.show());
      await tester.pump();
      // Let the indicator's snap-in animation (150ms) finish so onRefresh
      // actually gets called and is now awaiting our still-open gate.
      await tester.pump(const Duration(milliseconds: 200));

      // The bug: _load() unconditionally set loading state, which swapped
      // the whole body to a bare Center(CircularProgressIndicator) — ripping
      // out the RefreshIndicator and the list underneath it. With the fix,
      // both stay mounted while the refresh is in flight.
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(find.text('Plugin A'), findsOneWidget);
      expect(find.text('Plugin B'), findsOneWidget);

      service.fetchGate!.complete(_catalog);
      await settle(tester); // drains _load's continuation + the dismiss animation

      expect(find.text('Plugin A'), findsOneWidget);
    });
  });
}
