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

  @override
  Future<List<LnReaderPluginMeta>> fetchIndex() async => _catalog;
  @override
  Future<void> install(LnReaderPluginMeta meta) async => _installed[meta.id] = meta;
  @override
  List<LnReaderPluginMeta> installed() => _installed.values.toList();
  @override
  Future<void> uninstall(String id) async => _installed.remove(id);
  @override
  String? jsFor(String id) => _installed.containsKey(id) ? '/*js*/' : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLnrService service;

  setUp(() {
    service = _FakeLnrService();
    sl.registerSingleton<LnReaderExtensionService>(service);
    sl.registerSingleton<LnReaderManager>(
      LnReaderManager(
        service: service,
        fetch: (url, init) async => throw StateError(
          'fetch should not be called — the screen never loads the runtime',
        ),
      ),
    );
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

      expect(service.installed(), isEmpty);
      expect(find.text('Install'), findsNWidgets(2));
      await drainSnackBars(tester);
    });
  });
}
