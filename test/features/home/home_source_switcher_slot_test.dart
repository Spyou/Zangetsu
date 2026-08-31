import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/source_switcher.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/home_screen.dart';

/// [SourceSwitcher]'s closed-chip render (this suite never taps it open)
/// only touches [ProviderRegistry.entryFor] for an unprefixed id — a bare
/// fake is enough, no need for the real registry's Dio/download machinery.
class _FakeProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;
  @override
  List<ProviderRegistryEntry> getAll() => const [];
}

void main() {
  late Directory tempDir;
  late ActiveSourceCubit activeSource;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_switcher_slot_test');
    Hive.init(tempDir.path);
    await ZModePrefs.init();

    sl.registerSingleton<ProviderRegistry>(_FakeProviderRegistry());
    activeSource = ActiveSourceCubit();
    sl.registerSingleton<ActiveSourceCubit>(activeSource);
  });

  tearDown(() async {
    await activeSource.close();
    await sl.reset();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpSlot(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<ActiveSourceCubit>.value(
            value: activeSource,
            child: const HomeSourceSwitcherSlot(),
          ),
        ),
      ),
    );
  }

  testWidgets('Z Mode off: the source switcher shows', (tester) async {
    expect(ZModePrefs.enabled, isFalse);
    await pumpSlot(tester);
    expect(find.byType(SourceSwitcher), findsOneWidget);
  });

  testWidgets('Z Mode on: the source switcher is hidden', (tester) async {
    // A real Hive write never drains under the pump-driven testWidgets
    // binding without runAsync — same gotcha as wrong_title_sheet_test.dart.
    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    await pumpSlot(tester);
    expect(find.byType(SourceSwitcher), findsNothing);
  });

  testWidgets('flipping the toggle updates the slot without a restart', (tester) async {
    await pumpSlot(tester);
    expect(find.byType(SourceSwitcher), findsOneWidget);

    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    await tester.pump();
    expect(find.byType(SourceSwitcher), findsNothing);

    await tester.runAsync(() => ZModePrefs.setEnabled(false));
    await tester.pump();
    expect(find.byType(SourceSwitcher), findsOneWidget);
  });
}
