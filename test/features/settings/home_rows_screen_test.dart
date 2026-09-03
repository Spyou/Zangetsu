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
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/ui/home_rows_prefs.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
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

class _FakeTracker implements Tracker {
  _FakeTracker(this.name, {this.connected = true});

  final String name;
  final bool connected;

  @override
  String get displayName => name;
  @override
  bool get isConnected => connected;
  @override
  bool get supportsReading => true;
  @override
  Future<List<TrackerListItem>> fetchList() async => const [];
  @override
  void addListener(VoidCallback _) {}
  @override
  void removeListener(VoidCallback _) {}
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
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

  /// The editor lists every row of the layout — 15+ on AniList anime — which
  /// does not fit the 800x600 default surface, so taps on the lower rows land
  /// outside the render tree. Give it a phone.
  Future<void> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: HomeRowsScreen()));
    await tester.pumpAndSettle();
  }

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
    sl.registerSingleton<TrackerHub>(TrackerHub([_FakeTracker('AniList')]));
    await pumpEditor(tester);

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
    // Discover: AniList's own rows, read from the catalogue's static list
    // rather than whatever the last fetch happened to return.
    for (final t in AniListCatalogue.rowTitles(ZKind.anime)) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Trending'), findsOneWidget);

    // Defaults: local + sections on, tracker rows hidden.
    expect(tester.widget<Switch>(switchOf('local:continue')).value, isTrue);
    expect(tester.widget<Switch>(switchOf('section:Trending')).value, isTrue);
    expect(tester.widget<Switch>(switchOf('tracker:watching')).value, isFalse);
  });

  testWidgets('the layout provider is also the tracker behind its rows', (
    tester,
  ) async {
    sl.registerSingleton<TrackerHub>(
      TrackerHub([_FakeTracker('AniList'), _FakeTracker('MyAnimeList')]),
    );

    await pumpEditor(tester);

    // One control, not two: no separate account picker to reconcile.
    expect(find.text('Rows come from'), findsNothing);
    expect(find.text('Continue on AniList'), findsOneWidget);

    await tester.tap(find.text('Editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MyAnimeList \u00b7 Anime').last);
    await tester.pumpAndSettle();

    // Picking MAL's layout moves the list rows to MAL too.
    expect(find.text('Continue on MyAnimeList'), findsOneWidget);
    expect(find.text('Continue on AniList'), findsNothing);
  });

  testWidgets('signed out of the layout provider means no list rows', (
    tester,
  ) async {
    sl.registerSingleton<TrackerHub>(
      TrackerHub([
        _FakeTracker('AniList', connected: false),
        _FakeTracker('MyAnimeList'),
      ]),
    );

    await pumpEditor(tester);

    // The AniList layout is open and AniList isn't signed in. MAL's lists are
    // not a stand-in for it — switch to the MyAnimeList layout for those.
    expect(switchOf('tracker:watching'), findsNothing);
    expect(find.textContaining('Continue on'), findsNothing);
    expect(switchOf('local:continue'), findsOneWidget);
  });

  testWidgets('a layout no connected tracker can serve offers no list rows', (
    tester,
  ) async {
    // TMDB has no account of its own, and AniList holds no movie library
    // either. Nothing can fill list rows here.
    sl.registerSingleton<TrackerHub>(TrackerHub([_FakeTracker('AniList')]));

    await pumpEditor(tester);
    await tester.tap(find.text('Editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TMDB \u00b7 Movies & TV').last);
    await tester.pumpAndSettle();

    expect(find.text('DISCOVER'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    // The local row survives — it is history, not a tracker.
    expect(switchOf('local:continue'), findsOneWidget);
    expect(switchOf('tracker:watching'), findsNothing);
    expect(find.textContaining('Continue on'), findsNothing);
  });

  testWidgets('TMDB never offers list rows, even with Simkl signed in', (
    tester,
  ) async {
    sl.registerSingleton<TrackerHub>(
      TrackerHub([_FakeTracker('AniList'), _FakeTracker('Simkl')]),
    );

    await pumpEditor(tester);
    await tester.tap(find.text('Editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TMDB \u00b7 Movies & TV').last);
    await tester.pumpAndSettle();

    // Simkl holds movie lists, but this is the TMDB home — showing Simkl's
    // library under it read as if it were TMDB's.
    expect(switchOf('tracker:watching'), findsNothing);
    expect(find.text('Continue on Simkl'), findsNothing);

    // Simkl's own layout is where those live.
    await tester.tap(find.text('Editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simkl \u00b7 Movies & TV').last);
    await tester.pumpAndSettle();
    expect(find.text('Continue on Simkl'), findsOneWidget);
  });

  testWidgets('a reading layout drops New Episodes and reads Continue Reading', (
    tester,
  ) async {
    sl.registerSingleton<TrackerHub>(TrackerHub([_FakeTracker('AniList')]));

    await pumpEditor(tester);
    // Anime first: the row exists there.
    expect(find.text('New Episodes'), findsOneWidget);
    expect(find.text('Continue Watching'), findsOneWidget);

    await tester.tap(find.text('Editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AniList \u00b7 Manga').last);
    await tester.pumpAndSettle();

    // Chapters have no airing schedule, so there is no new-episode feed to
    // offer — Home never builds that row for a reading kind.
    expect(find.text('New Episodes'), findsNothing);
    expect(switchOf('tracker:new-episodes'), findsNothing);
    // And the local row is named for what Home actually renders here.
    expect(find.text('Continue Reading'), findsOneWidget);
    expect(find.text('Continue Watching'), findsNothing);
    // The status buckets relabel too.
    expect(find.text('Reading'), findsOneWidget);
    expect(find.text('Plan to Read'), findsOneWidget);
  });

  testWidgets('a source-backed home waits for its sections', (tester) async {
    // Only a source-backed layout depends on a fetch — a metadata layout
    // declares its rows, so it is editable the moment the screen opens.
    // setEnabled awaits Hive's disk flush, which the fake test clock never
    // delivers — without a real event loop this hangs until pumpAndSettle's
    // 10-minute timeout. (HomeRowsPrefs.save sidesteps it by not awaiting.)
    await tester.runAsync(() => ZModePrefs.setEnabled(false));
    addTearDown(() => tester.runAsync(() => ZModePrefs.setEnabled(true)));
    final pending = HomeCubit(const _StubRepo());
    addTearDown(pending.close);
    await sl.unregister<HomeCubit>();
    sl.registerSingleton<HomeCubit>(pending);

    await pumpEditor(tester);

    expect(find.text('Loading\u2026'), findsOneWidget);
    expect(switchOf('local:continue'), findsNothing);

    pending.emit(
      HomeState(sections: [_section('Trending'), _section('Popular')]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Loading\u2026'), findsNothing);
    expect(switchOf('local:continue'), findsOneWidget);
    // No tracker rows on a source-backed home, and the phone drops the first
    // section of a non-zm source.
    expect(find.text('Popular'), findsOneWidget);
    expect(switchOf('tracker:watching'), findsNothing);
  });

  testWidgets('every layout is reachable without switching mode', (
    tester,
  ) async {
    await pumpEditor(tester);

    expect(find.text('AniList \u00b7 Anime'), findsOneWidget); // the tile

    await tester.tap(find.text('Editing'));
    await tester.pumpAndSettle();

    // All eight, both sides of each provider pair — arranging the one you are
    // about to switch to shouldn't require switching first.
    for (final label in [
      'AniList \u00b7 Anime',
      'AniList \u00b7 Manga',
      'AniList \u00b7 Novel',
      'MyAnimeList \u00b7 Anime',
      'MyAnimeList \u00b7 Manga',
      'MyAnimeList \u00b7 Novel',
      'TMDB \u00b7 Movies & TV',
      'Simkl \u00b7 Movies & TV',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
  });

  testWidgets('switching layout edits that key, leaving the other alone', (
    tester,
  ) async {
    await pumpEditor(tester);

    await tester.tap(find.text('Editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simkl \u00b7 Movies & TV').last);
    await tester.pumpAndSettle();

    // Simkl's own Discover rows now, not AniList's.
    expect(find.text('Trending movies'), findsOneWidget);
    expect(find.text('Popular this season'), findsNothing);

    await tester.tap(switchOf('section:Trending movies'));
    await tester.pump();
    await flushWrites(tester);

    expect(HomeRowsPrefs.savedFor('simkl::movie'), isNotNull);
    expect(
      HomeRowsPrefs.savedFor('simkl::movie'),
      contains('!section:Trending movies'),
    );
    // The layout the app is actually in was never touched.
    expect(HomeRowsPrefs.savedFor(layoutKey), isNull);
  });

  testWidgets('toggling a row off persists the whole arrangement with a mark', (
    tester,
  ) async {
    sl.registerSingleton<TrackerHub>(TrackerHub([_FakeTracker('AniList')]));
    await pumpEditor(tester);

    // Trending is on by default; tapping its switch hides it.
    await tester.tap(switchOf('section:Trending'));
    await tester.pump();
    await flushWrites(tester);

    final saved = HomeRowsPrefs.savedFor(layoutKey);
    expect(saved, isNotNull);
    expect(saved, contains('!section:Trending'));
    expect(saved, isNot(contains('section:Trending'))); // no bare duplicate
    // Untouched rows keep their default visibility in the same save.
    expect(saved, contains('local:continue'));
    expect(saved, contains('!tracker:planning'));
    expect(saved, contains('section:Recently released'));
    // The switch the test just flipped reflects it in the UI too.
    expect(
      tester.widget<Switch>(switchOf('section:Trending')).value,
      isFalse,
    );
  });

  testWidgets('reset clears the saved arrangement and restores defaults', (
    tester,
  ) async {
    sl.registerSingleton<TrackerHub>(TrackerHub([_FakeTracker('AniList')]));
    await pumpEditor(tester);

    await tester.tap(switchOf('section:Trending'));
    await tester.pump();
    await flushWrites(tester);
    expect(HomeRowsPrefs.savedFor(layoutKey), isNotNull);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    await flushWrites(tester);

    expect(HomeRowsPrefs.savedFor(layoutKey), isNull);
    expect(tester.widget<Switch>(switchOf('section:Trending')).value, isTrue);
    expect(tester.widget<Switch>(switchOf('tracker:watching')).value, isFalse);
  });
}
