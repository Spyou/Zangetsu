import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/backup/backup_service.dart';
import 'package:watch_app/core/backup/library_backup.dart';
import 'package:watch_app/core/backup/settings_backup.dart';
import 'package:watch_app/core/backup/sources_backup.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/backup/backup_screen.dart';

MigrationBridge _fakeBridge() => MigrationBridge(
      invoke: (_, __) async => const {'ok': false},
      signInPassword: (_, __) async => false,
      verifyOtp: (_, __) async => false,
    );

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubRegistry implements ProviderRegistry {
  @override
  List<ProviderRegistryEntry> getAll() => const [];
  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;
  @override
  Set<String> nsfwSourceIds() => const {};
  @override
  Stream<BoxEvent> watch() => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubReposRegistry implements ProviderReposRegistry {
  @override
  List<ProviderRepo> getAll() => const [];
  @override
  Stream<BoxEvent> watch() => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => '/tmp/test',
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    // Mock path_provider before AppwriteService is constructed: its Appwrite
    // Client asynchronously requests the app documents directory, and doing
    // this here (rather than only in the test body) avoids a cross-test race
    // once more than one test in this file constructs an AppwriteService.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => '/tmp/test');
    sl
      ..registerSingleton<AppwriteService>(AppwriteService())
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<BackupService>(BackupService(
        SourcesBackup(_StubReposRegistry(), _StubRegistry(), null),
        LibraryBackup(),
        SettingsBackup(),
      ));
  });

  tearDown(() => sl.reset());

  testWidgets(
    'BackupScreen renders three bundle checkboxes and four action buttons',
    (tester) async {
      _mockPathProvider(tester);
      // Tall surface so the lazy ListView builds every tile (the screen is
      // longer than the default 800px test viewport).
      await tester.binding.setSurfaceSize(const Size(1000, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = AuthCubit(SupabaseService(), sl<AppwriteService>(), _fakeBridge());
      addTearDown(auth.close);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider<AuthCubit>.value(
            value: auth,
            child: const BackupScreen(),
          ),
        ),
      );
      await tester.pump();

      // Three bundle checkboxes (all checked by default).
      expect(find.text('Sources & repos'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('App settings'), findsOneWidget);

      // Four action buttons (SettingsTile labels).
      expect(find.text('Back up to cloud'), findsOneWidget);
      expect(find.text('Save to a file'), findsOneWidget);
      expect(find.text('Restore from cloud'), findsOneWidget);
      expect(find.text('Restore from a file'), findsOneWidget);
    },
  );

  Future<void> pumpBackup(WidgetTester tester) async {
    _mockPathProvider(tester);
    await tester.binding.setSurfaceSize(const Size(1000, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final auth = AuthCubit(SupabaseService(), sl<AppwriteService>(), _fakeBridge());
    addTearDown(auth.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<AuthCubit>.value(value: auth, child: const BackupScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('TV: backup rows are wrapped in TvFocusable', (tester) async {
    sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    await pumpBackup(tester);
    // 4 action tiles + 3 bundle checkbox rows → at least 4 focusable rows.
    expect(
      tester.widgetList<TvFocusable>(find.byType(TvFocusable)).length,
      greaterThanOrEqualTo(4),
    );
  });

  testWidgets('phone: BackupScreen adds no TvFocusable (unchanged)', (tester) async {
    // setUp registered AppMode(isTv: false) — phone path.
    await pumpBackup(tester);
    expect(find.byType(TvFocusable), findsNothing);
  });
}
