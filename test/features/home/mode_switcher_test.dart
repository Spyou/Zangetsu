import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/mode_switcher.dart';

void main() {
  late Directory hiveDir;
  late ActiveSourceCubit activeSource;
  late ContentModeCubit modeCubit;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('mode_switcher_test');
    Hive.init(hiveDir.path);
    activeSource = ActiveSourceCubit();
    modeCubit = await ContentModeCubit.create(activeSource);
    sl.registerSingleton<ActiveSourceCubit>(activeSource);
    sl.registerSingleton<ContentModeCubit>(modeCubit);
  });

  tearDown(() async {
    await modeCubit.close();
    await activeSource.close();
    await sl.reset();
    await Hive.close();
    if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
  });

  testWidgets('pill shows current mode and switches via sheet', (tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ModeSwitcher())),
    );
    await tester.tap(find.byType(ModeSwitcher));
    await tester.pumpAndSettle();

    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.text('Novel'), findsOneWidget);

    // setMode emits synchronously now (persistence is fire-and-forget), so
    // the mode change itself doesn't need the real event loop — but the
    // fire-and-forget Hive writes are real I/O, and FakeAsync (which
    // testWidgets runs in) never drains that on its own; without runAsync
    // here those writes dangle and tearDown's Hive.close() hangs waiting on
    // them.
    await tester.runAsync(() async {
      await tester.tap(find.text('Manga'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(sl<ContentModeCubit>().state, ContentMode.manga);
  });

  testWidgets('renders nothing on TV', (tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ModeSwitcher())),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(ModeSwitcher)), Size.zero);
  });
}
