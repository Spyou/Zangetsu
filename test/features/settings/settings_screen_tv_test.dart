import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/settings/settings_screen_tv.dart';

MigrationBridge _fakeBridge() => MigrationBridge(
      invoke: (_, __) async => const {'ok': false},
      signInPassword: (_, __) async => false,
      verifyOtp: (_, __) async => false,
    );

// ── Minimal stubs ─────────────────────────────────────────────────────────────

/// [SearchPrefs] stub: overrides [layout] so no Hive box is accessed.
class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

/// [ProviderRegistry] stub: returns empty entries; no Hive dependency.
class _StubProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  Set<String> nsfwSourceIds() => const {};
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Registers the minimal GetIt singletons needed for [SettingsScreenTv.build].
///
/// On a non-Android host (macOS test runner) only [SearchPrefs] and
/// [ProviderRegistry] are accessed at build time. Android-only tiles that touch
/// [CloudStreamManager] are guarded by [Platform.isAndroid] and are never
/// rendered in tests.
void _registerStubs() {
  final sl = GetIt.instance;
  sl.registerSingleton<SearchPrefs>(_StubSearchPrefs());
  sl.registerSingleton<ProviderRegistry>(_StubProviderRegistry());
}

/// Mocks the path_provider platform channel so that [AppwriteService] —
/// which internally creates an Appwrite [Client] that asynchronously requests
/// the app documents directory — does not throw [MissingPluginException]
/// during tests. Called inside each [testWidgets] body after the binding is
/// initialized (it cannot be called in [setUp] before the binding exists).
void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => '/tmp/test',
  );
}

Widget _buildUnderTest({
  required AuthCubit authCubit,
  required ActiveSourceCubit activeCubit,
}) =>
    MultiBlocProvider(
      providers: [
        BlocProvider<AuthCubit>.value(value: authCubit),
        BlocProvider<ActiveSourceCubit>.value(value: activeCubit),
      ],
      child: const MaterialApp(home: SettingsScreenTv()),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late ActiveSourceCubit activeCubit;
  late Directory hiveDir;

  setUp(() async {
    // SettingsScreenTv.initState creates an UpdateService and reads its beta
    // opt-in, which opens the "updates" Hive box. Point Hive at a temp dir so
    // that box open succeeds instead of throwing "Hive not initialized".
    hiveDir = await Directory.systemTemp.createTemp('settings_tv_test');
    Hive.init(hiveDir.path);
    _registerStubs();
    // ActiveSourceCubit with box=null falls back to 'allanime' — no Hive.
    activeCubit = ActiveSourceCubit();
  });

  tearDown(() async {
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  testWidgets(
    'SettingsScreenTv renders key tile titles and the first TvFocusable has autofocus',
    (tester) async {
      // Mock path_provider before AppwriteService is created (Client async init).
      _mockPathProvider(tester);
      final authCubit = AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      // Page title is displayed.
      expect(find.text('Settings'), findsOneWidget);

      // Tiles that are visible in the default 800×600 test viewport (the
      // ListView lazy-builds only what fits; Storage and below are off-screen).
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Backup & Restore'), findsOneWidget);
      expect(find.text('Providers'), findsOneWidget);
      expect(find.text('Active source'), findsOneWidget);
      expect(find.text('Source health'), findsOneWidget);
      expect(find.text('Playback'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Search layout'), findsOneWidget);

      // At least several tiles are wrapped in TvFocusable.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(5));

      // The very first TvFocusable (the Sign-in / account tile) carries
      // autofocus=true so the D-pad lands on it when the Settings page opens.
      expect(focusables.first.autofocus, isTrue);
    },
  );

  testWidgets(
    'SettingsScreenTv shows Sign-in tile when unauthenticated',
    (tester) async {
      _mockPathProvider(tester);
      final authCubit = AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      // In the unauthenticated state the Sign-in tile is the first item.
      expect(find.text('Sign in'), findsOneWidget);
      // Profile-specific text must not appear in the guest state.
      expect(find.text('Profile'), findsNothing);
    },
  );

  testWidgets(
    'SettingsScreenTv only the first TvFocusable has autofocus=true',
    (tester) async {
      _mockPathProvider(tester);
      final authCubit = AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();

      // Guard: at least one focusable must be built.
      expect(focusables, isNotEmpty);

      // The first TvFocusable (account card) always carries autofocus=true.
      expect(focusables.first.autofocus, isTrue);

      // All subsequent TvFocusable tiles have autofocus=false (D-pad navigates
      // between them; only the initial landing tile needs autofocus).
      for (final f in focusables.skip(1)) {
        expect(f.autofocus, isFalse);
      }
    },
  );

  testWidgets(
    'SettingsScreenTv exposes semantics labels for its tiles — with no '
    'duplicate-text nodes',
    (tester) async {
      _mockPathProvider(tester);
      final authCubit = AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      // Guest state: the Sign-in tile is first and carries autofocus. Its
      // ListTile/SettingsTile content is excluded, so this is the only node.
      expect(
        tester.getSemantics(find.bySemanticsLabel('Sign in')),
        matchesSemantics(
          label: 'Sign in',
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasTapAction: true,
          // Framework-supplied for anything focusable; matchesSemantics fails
          // on any action it wasn't told to expect.
          hasFocusAction: true,
        ),
      );

      // A few more tiles visible in the default test viewport, each a
      // single announced node (no separate title/subtitle Text nodes).
      for (final label in ['Providers', 'Active source', 'Source health']) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          matchesSemantics(
            label: label,
            isButton: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
      }

      handle.dispose();
    },
  );
}
