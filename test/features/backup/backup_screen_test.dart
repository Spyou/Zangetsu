import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/backup/backup_service.dart';
import 'package:watch_app/core/backup/library_backup.dart';
import 'package:watch_app/core/backup/settings_backup.dart';
import 'package:watch_app/core/backup/sources_backup.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/backup/backup_screen.dart';

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
    sl
      ..registerSingleton<AppwriteService>(AppwriteService())
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

      final auth = AuthCubit(sl<AppwriteService>());
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
      expect(find.text('Save to file'), findsOneWidget);
      expect(find.text('Restore from cloud'), findsOneWidget);
      expect(find.text('Restore from file'), findsOneWidget);
    },
  );
}
