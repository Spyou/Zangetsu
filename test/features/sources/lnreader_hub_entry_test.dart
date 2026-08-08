// Task 3: LNReader (novel sources) gets a hub row alongside Mihon, mirroring
// `mihon_hub_entry_test.dart`. Unlike Mihon (Platform.isAndroid-gated),
// LNReader is a JS provider available on every platform, so its row is
// gated on `sl.isRegistered<LnReaderManager>()` instead — a test that never
// registers LnReaderManager (e.g. manga_novel_hub_entry_test.dart) must keep
// working unchanged.
//
// Uses the same in-memory fake LnReaderExtensionService as
// lnreader_sources_screen_test.dart — a real Hive box does file I/O that
// never resolves under the widget-test zone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/lnreader_sources_screen.dart';
import 'package:watch_app/features/sources/providers_hub_screen.dart';

// ---------------------------------------------------------------------------
// Fakes — same shape as mihon_hub_entry_test.dart's (private to that file,
// re-declared here rather than shared).
// ---------------------------------------------------------------------------

class _FakeProviderRegistry implements ProviderRegistry {
  _FakeProviderRegistry(this._entries);
  final List<ProviderRegistryEntry> _entries;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => _entries;

  @override
  ProviderRegistryEntry? entryFor(String sourceId) {
    for (final e in _entries) {
      if (e.name == sourceId) return e;
    }
    return null;
  }

  @override
  Set<String> nsfwSourceIds() => const {};

  @override
  String? typeOf(String sourceId) => null;

  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();
}

class _FakeReposRegistry implements ProviderReposRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRepo> getAll() => const [];

  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();
}

/// In-memory fake, same as lnreader_sources_screen_test.dart's — no real
/// Hive box, no network.
class _FakeLnrService extends LnReaderExtensionService {
  _FakeLnrService() : super(httpGet: (_) async => '');
  final Map<String, LnReaderPluginMeta> _installed = {};

  void seed(LnReaderPluginMeta meta) => _installed[meta.id] = meta;

  @override
  Future<List<LnReaderPluginMeta>> fetchIndex() async => const [];
  @override
  Future<void> install(LnReaderPluginMeta meta) async => _installed[meta.id] = meta;
  @override
  List<LnReaderPluginMeta> installed() => _installed.values.toList();
  @override
  Future<void> uninstall(String id) async => _installed.remove(id);
  @override
  String? jsFor(String id) => _installed.containsKey(id) ? '/*js*/' : null;
}

const _pluginA = LnReaderPluginMeta(
  id: 'plugin-a',
  name: 'Plugin A',
  site: 'https://a.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/a.js',
  iconUrl: 'https://cdn.test/a.png',
);

void main() {
  final sl = GetIt.instance;
  late _FakeLnrService lnrService;

  setUp(() {
    final entries = [
      ProviderRegistryEntry(
        name: 'anime1',
        url: 'bundled://anime1',
        displayName: 'Anime One',
      ),
      ProviderRegistryEntry(
        name: 'anime2',
        url: 'bundled://anime2',
        displayName: 'Anime Two',
      ),
    ];
    lnrService = _FakeLnrService();
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<ProviderRegistry>(_FakeProviderRegistry(entries))
      ..registerSingleton<ProviderReposRegistry>(_FakeReposRegistry())
      ..registerSingleton<CloudStreamManager>(CloudStreamManager())
      ..registerSingleton<AniyomiManager>(AniyomiManager())
      ..registerSingleton<MihonManager>(MihonManager())
      ..registerSingleton<LnReaderExtensionService>(lnrService)
      ..registerSingleton<LnReaderManager>(
        LnReaderManager(
          service: lnrService,
          fetch: (url, init) async => throw StateError(
            'fetch should not be called — the hub never touches the runtime',
          ),
        ),
      )
      ..registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: ''));
  });

  tearDown(() async {
    await sl.reset();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ProvidersHubScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('LNReader row shows up under MANGA & NOVEL with its source count',
      (tester) async {
    lnrService.seed(_pluginA);
    await pump(tester);

    expect(find.text('MANGA & NOVEL'), findsOneWidget);
    expect(find.text('LNReader'), findsOneWidget);
    expect(find.text('Novel sources'), findsOneWidget);
    expect(find.text('1 sources'), findsOneWidget);
  });

  testWidgets('tapping the LNReader row pushes LnReaderSourcesScreen',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text('LNReader'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(LnReaderSourcesScreen), findsOneWidget);
  });

  testWidgets(
    'LNReader row is absent when LnReaderManager is not registered — the '
    'guard existing minimal-GetIt tests rely on',
    (tester) async {
      await sl.unregister<LnReaderManager>();
      await sl.unregister<LnReaderExtensionService>();
      await pump(tester);

      expect(find.text('MANGA & NOVEL'), findsNothing);
      expect(find.text('LNReader'), findsNothing);
    },
  );

  testWidgets(
    'an lnr: active id badges the LNReader row ACTIVE and does not badge the '
    'Zangetsu row',
    (tester) async {
      lnrService.seed(_pluginA);
      await sl.unregister<ActiveSourceCubit>();
      sl.registerSingleton<ActiveSourceCubit>(
        ActiveSourceCubit(fallback: 'lnr:plugin-a'),
      );
      await pump(tester);

      expect(find.text('ACTIVE'), findsOneWidget);
    },
  );

  testWidgets(
    'a registered LNReader source is included in the header total',
    (tester) async {
      lnrService.seed(_pluginA);
      await pump(tester);

      // 2 Zangetsu entries + 1 LNReader source.
      expect(find.text('3 sources ready'), findsOneWidget);
    },
  );
}
