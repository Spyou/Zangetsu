import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/sources/bloc/sources_bloc.dart';
import 'package:watch_app/features/sources/sources_screen_tv.dart';

// ── Minimal stubs ─────────────────────────────────────────────────────────────

/// [ProviderRegistry] stub: returns fixed entries; never touches Hive.
/// [watch] returns an empty stream so [SourcesBloc]'s subscription
/// compiles and never fires.
class _StubRegistry implements ProviderRegistry {
  _StubRegistry(this._entries);
  final List<ProviderRegistryEntry> _entries;

  @override
  List<ProviderRegistryEntry> getAll() => _entries;

  @override
  ProviderRegistryEntry? entryFor(String sourceId) =>
      _entries.where((e) => e.name == sourceId).firstOrNull;

  @override
  Set<String> nsfwSourceIds() => const {};

  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();

  // All Hive/install/uninstall paths are not invoked during widget rendering.
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// [ProviderReposRegistry] stub: no repos, never emits events.
class _StubReposRegistry implements ProviderReposRegistry {
  @override
  List<ProviderRepo> getAll() => const [];

  @override
  Stream<BoxEvent> watch() => const Stream<BoxEvent>.empty();

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Factories ─────────────────────────────────────────────────────────────────

/// Creates a realistic [ProviderRegistryEntry] for tests.
ProviderRegistryEntry _entry({
  required String name,
  required String displayName,
  bool bundled = false,
  bool enabled = true,
  String version = '1.0.0',
}) =>
    ProviderRegistryEntry(
      name: name,
      url: bundled ? 'bundled://$name' : 'https://example.com/$name.js',
      version: version,
      enabled: enabled,
      originRepoUrl: bundled ? kBundledRepoUrl : 'https://example.com/index.json',
      displayName: displayName,
    );

/// Builds the bloc under test with two installed providers (one bundled,
/// one from a repo). The stub registries avoid any Hive dependency.
SourcesBloc _makeFakeBloc() {
  final registry = _StubRegistry([
    _entry(name: 'allanime', displayName: 'AllAnime', bundled: true),
    _entry(name: 'animixplay', displayName: 'AnimixPlay'),
  ]);
  return SourcesBloc(
    registry: registry,
    repos: _StubReposRegistry(),
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Mocks [path_provider]'s platform channel so that any async platform
/// channel call made during widget setup (e.g. by AppwriteService) doesn't
/// throw [MissingPluginException].
void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => '/tmp/test',
  );
}

Widget _buildUnderTest(SourcesBloc bloc) => MaterialApp(
      home: SourcesScreenTv(bloc: bloc),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late SourcesBloc bloc;

  setUp(() {
    bloc = _makeFakeBloc();
  });

  tearDown(() async {
    await bloc.close();
  });

  testWidgets(
    'SourcesScreenTv renders page title and installed provider names',
    (tester) async {
      _mockPathProvider(tester);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pumpAndSettle();

      // Page title.
      expect(find.text('Providers'), findsWidgets);

      // Section header is rendered.
      expect(find.text('INSTALLED'), findsOneWidget);

      // Source display names appear.
      expect(find.text('AllAnime'), findsOneWidget);
      expect(find.text('AnimixPlay'), findsOneWidget);
    },
  );

  testWidgets(
    'SourcesScreenTv renders TvFocusable widgets and first has autofocus',
    (tester) async {
      _mockPathProvider(tester);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pumpAndSettle();

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();

      // At least the section header + per-source action buttons.
      expect(focusables.length, greaterThanOrEqualTo(3));

      // The very first TvFocusable (Installed section header) has
      // autofocus=true so D-pad focus lands there when the screen opens.
      expect(focusables.first.autofocus, isTrue);
    },
  );

  testWidgets(
    'SourcesScreenTv only the first TvFocusable has autofocus=true',
    (tester) async {
      _mockPathProvider(tester);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pumpAndSettle();

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();

      expect(focusables, isNotEmpty);

      // First TvFocusable: autofocus = true.
      expect(focusables.first.autofocus, isTrue);

      // All subsequent TvFocusables: autofocus = false.
      for (final f in focusables.skip(1)) {
        expect(f.autofocus, isFalse);
      }
    },
  );

  testWidgets(
    'SourcesScreenTv action buttons render for each installed source',
    (tester) async {
      _mockPathProvider(tester);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pumpAndSettle();

      // Each installed row has at minimum: enable-switch TvFocusable + gear
      // TvFocusable = 2 per source × 2 sources = 4 action TvFocusables.
      // Plus section header = at least 5 TvFocusables total.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(5));

      // Settings-gear icon is rendered for each source (verifies the
      // settings TvFocusable is in the tree).
      expect(
        find.byIcon(Icons.tune_rounded),
        findsNWidgets(2),
      );

      // Remove button is only on the non-bundled source (AnimixPlay).
      expect(
        find.byIcon(Icons.delete_outline_rounded),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'SourcesScreenTv shows empty state when no providers installed',
    (tester) async {
      _mockPathProvider(tester);

      final emptyBloc = SourcesBloc(
        registry: _StubRegistry(const []),
        repos: _StubReposRegistry(),
      );
      addTearDown(emptyBloc.close);

      await tester.pumpWidget(_buildUnderTest(emptyBloc));
      await tester.pumpAndSettle();

      expect(find.text('No providers installed.'), findsOneWidget);
    },
  );
}
