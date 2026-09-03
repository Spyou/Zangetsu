import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/ui/home_rows_prefs.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/settings/home_rows_screen.dart';

// The editor edits the CURRENT layout through the same composer the cubit
// merges with (pure functions covered by home_rows_composer_test). These pump
// the screen against a HomeCubit already holding sections and check the three
// things the screen itself owns: grouping, toggling into storage, and reset.

class _StubRepo implements CatalogueRepository {
  const _StubRepo();

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get sourceId => 'test';
}

HomeSection _section(String title) => HomeSection(
  title: title,
  items: const [
    MediaItem(
      id: 'x',
      title: 'Show',
      url: '',
      type: ProviderType.anime,
      sourceId: '',
    ),
  ],
);

void main() {
  late Directory dir;
  // Z Mode defaults on + anime, and no provider prefs are registered, so the
  // layout under edit is 'anilist::anime'.
  const layoutKey = 'anilist::anime';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('home_rows_screen_test');
    Hive.init(dir.path);
    await ZModePrefs.init();
    await HomeRowsPrefs.init();

    await sl.reset();
    sl.registerSingleton<AppMode>(AppMode(isTv: false));
    final cubit = HomeCubit(const _StubRepo());
    addTearDown(cubit.close);
    // Phone rule: the first section of a non-zm source is dropped from the
    // rows (it feeds the banner), so Discover offers only the rest.
    cubit.emit(
      HomeState(sections: [_section('Trending'), _section('Popular'), _section('Upcoming')]),
    );
    sl.registerSingleton<HomeCubit>(cubit);
    sl.registerSingleton<CatalogueRepository>(const _StubRepo());
  });

  tearDown(() async {
    await sl.reset();
    // The fake clock can't flush Hive's pending disk write, so close() can
    // neither be awaited (hangs the test) nor trusted to finish cleanly —
    // fire it, swallow its errors, and let the box reopen fresh per setUp.
    unawaited(() async {
      try {
        await Hive.close();
      } catch (_) {}
    }());
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // close() deletes the box lock file concurrently with this.
    }
  });

  /// Each editor row is keyed by its persistence id; the switch is a
  /// descendant of the row (a sibling of the title text, so ancestor-of-text
  /// finders can't reach it).
  Finder switchOf(String rowId) => find.descendant(
    of: find.byKey(ValueKey(rowId)),
    matching: find.byType(Switch),
  );

  /// A switch tap starts a real Hive disk write that the fake test clock
  /// can't deliver; without a genuine event-loop turn the awaited
  /// `Hive.close()` in tearDown never finishes and the test hangs (the known
  /// Hive-in-testWidgets hazard noted in nav_tabs_screen_test).
  Future<void> flushWrites(WidgetTester tester) => tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );

  testWidgets('shows both groups with tracker rows off and sections on', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomeRowsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('FROM YOUR LISTS'), findsOneWidget);
    expect(find.text('DISCOVER'), findsOneWidget);

    // Yours: the local row plus the tracker rows, labelled with the tracker
    // that would serve (none connected here, so the first in hub order).
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Continue on AniList'), findsOneWidget);
    expect(find.text('New Episodes'), findsOneWidget);
    for (final t in ['Watching', 'Planning', 'Paused', 'Dropped']) {
      expect(find.text(t), findsOneWidget);
    }
    // Discover: the sections that render as rows — Trending feeds the banner,
    // so it isn't offered.
    expect(find.text('Popular'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('Trending'), findsNothing);

    // Defaults: local + sections on, tracker rows hidden.
    expect(tester.widget<Switch>(switchOf('local:continue')).value, isTrue);
    expect(tester.widget<Switch>(switchOf('section:Popular')).value, isTrue);
    expect(tester.widget<Switch>(switchOf('tracker:watching')).value, isFalse);
  });

  testWidgets('toggling a row off persists the whole arrangement with a mark', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomeRowsScreen()));
    await tester.pumpAndSettle();

    // Popular is on by default; tapping its switch hides it.
    await tester.tap(switchOf('section:Popular'));
    await tester.pump();
    await flushWrites(tester);

    final saved = HomeRowsPrefs.savedFor(layoutKey);
    expect(saved, isNotNull);
    expect(saved, contains('!section:Popular'));
    expect(saved, isNot(contains('section:Popular'))); // no bare duplicate
    // Untouched rows keep their default visibility in the same save.
    expect(saved, contains('local:continue'));
    expect(saved, contains('!tracker:planning'));
    expect(saved, contains('section:Upcoming'));
    // The switch the test just flipped reflects it in the UI too.
    expect(
      tester.widget<Switch>(switchOf('section:Popular')).value,
      isFalse,
    );
  });

  testWidgets('reset clears the saved arrangement and restores defaults', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomeRowsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(switchOf('section:Popular'));
    await tester.pump();
    await flushWrites(tester);
    expect(HomeRowsPrefs.savedFor(layoutKey), isNotNull);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    await flushWrites(tester);

    expect(HomeRowsPrefs.savedFor(layoutKey), isNull);
    expect(tester.widget<Switch>(switchOf('section:Popular')).value, isTrue);
    expect(tester.widget<Switch>(switchOf('tracker:watching')).value, isFalse);
  });
}
