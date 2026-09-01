// The hub behind Home's single card. It replaced a card per tracker plus a
// Schedule card, so the thing worth pinning is that it stops depending on the
// mode: every connected tracker is listed no matter which mode you arrived in.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/home/lists_hub_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _FakeTracker implements Tracker {
  _FakeTracker(this.displayName, {required this.supportsReading,
      this.isConnected = true});

  @override
  final String displayName;
  @override
  final bool supportsReading;
  @override
  final bool isConnected;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget harness() => const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ListsHubScreen(),
    );

void main() {
  // Three trackers with three kinds each runs past a default test viewport, and
  // a ListView does not build what it cannot show. Give it room so the finders
  // are testing the screen rather than the scroll position.
  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(400 * 3, 1600 * 3);
    v.devicePixelRatio = 3;
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
    await sl.reset();
  });

  testWidgets('lists every connected tracker plus Schedule', (t) async {
    sl.registerSingleton<TrackerHub>(TrackerHub([
      _FakeTracker('AniList', supportsReading: true),
      _FakeTracker('MyAnimeList', supportsReading: true),
      _FakeTracker('Simkl', supportsReading: false),
    ]));

    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.text('Schedule'), findsOneWidget);
    // A section per tracker, and inside it a row per kind of list it holds.
    expect(find.text('ANILIST'), findsOneWidget);
    expect(find.text('MYANIMELIST'), findsOneWidget);
    expect(find.text('SIMKL'), findsOneWidget);
    // Anime, Manga and Novel for each of the two reading trackers.
    expect(find.text('Anime'), findsNWidgets(2));
    expect(find.text('Manga'), findsNWidgets(2));
    expect(find.text('Novel'), findsNWidgets(2));
    // Simkl has no reading side, so it gets one row saying what it does cover.
    expect(find.text('Movies and series'), findsOneWidget);
  });

  testWidgets('a disconnected tracker is not offered', (t) async {
    sl.registerSingleton<TrackerHub>(TrackerHub([
      _FakeTracker('AniList', supportsReading: true),
      _FakeTracker('Simkl', supportsReading: false, isConnected: false),
    ]));

    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.text('ANILIST'), findsOneWidget);
    expect(find.text('SIMKL'), findsNothing);
  });

  testWidgets('Schedule stands alone when nothing is connected', (t) async {
    // The row on Home is unconditional now, so this screen must not be empty
    // for someone with no trackers — Schedule is still worth the trip.
    sl.registerSingleton<TrackerHub>(TrackerHub([]));

    await t.pumpWidget(harness());
    await t.pumpAndSettle();

    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('YOUR LISTS'), findsNothing);
  });
}
