import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/ui/continue_card.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/features/home/tracker_continue_section.dart';

// The tracker-driven home rows render what the cubit sliced — titles, progress
// badges, reading relabels, taps — without fetching anything of their own.
// Pumped directly (like ContinueSection's tests) so no HomeCubit/DI beyond the
// AppMode ContentRow's RevealItem reads.

MediaItem _stub(String title, {ProviderType type = ProviderType.anime}) =>
    MediaItem(id: title, title: title, url: '', type: type, sourceId: '');

TrackerListItem _entry(
  String title, {
  int? progress,
  int? total,
  int? nextAiring,
  ProviderType type = ProviderType.anime,
  WatchStatus status = WatchStatus.watching,
}) => TrackerListItem(
  item: _stub(title, type: type),
  status: status,
  progress: progress,
  totalEpisodes: total,
  nextAiringEpisode: nextAiring,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  // Poster rows are 216 tall; three stacked ones do not fit the 800x600
  // default surface, and a gesture on an off-screen row lands nowhere.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });
  tearDown(() async {
    await sl.reset();
  });

  testWidgets('TrackerContinueSection: title, EP badge, tap opens the entry', (
    tester,
  ) async {
    TrackerListItem? opened;
    await _pump(
      tester,
      TrackerContinueSection(
        items: [_entry('One Piece', progress: 4, total: 12)],
        trackerName: 'AniList',
        onOpen: (e) => opened = e,
      ),
    );

    expect(find.text('Continue on AniList'), findsOneWidget);
    expect(find.text('One Piece'), findsOneWidget);
    expect(find.text('EP 4/12'), findsOneWidget);

    await tester.tap(find.text('One Piece'));
    expect(opened?.item.title, 'One Piece');
  });

  testWidgets('reading entries badge chapters, and drop an unknown total', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackerContinueSection(
        items: [_entry('Berserk', progress: 12, type: ProviderType.manga)],
        trackerName: 'MyAnimeList',
        onOpen: (_) {},
      ),
    );

    expect(find.text('Ch 12'), findsOneWidget);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('TrackerContinueSection is a poster row with no progress bar', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackerContinueSection(
        items: [_entry('One Piece', progress: 4, total: 12)],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );

    expect(find.byType(PosterCard), findsOneWidget);
    // A tracker has no playback position, so drawing its episode count as a
    // bar made it read as one. The count stays, the bar goes.
    expect(find.byType(ContinueCard), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('EP 4/12'), findsOneWidget);
  });

  testWidgets('caught up on an airing show says so instead of the fraction', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackerContinueSection(
        // Episode 7 airs next, so 6 are out and all 6 are watched. "EP 6/10"
        // would promise four episodes that do not exist yet.
        items: [_entry('Bleach', progress: 6, total: 10, nextAiring: 7)],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );

    expect(find.text('Caught up'), findsOneWidget);
    expect(find.text('EP 6/10'), findsNothing);
  });

  testWidgets('behind on an airing show still shows the fraction', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackerContinueSection(
        items: [_entry('Bleach', progress: 4, total: 10, nextAiring: 7)],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );

    expect(find.text('EP 4/10'), findsOneWidget);
    expect(find.text('Caught up'), findsNothing);
  });

  testWidgets('no next-airing (MAL, Simkl) never claims caught up', (
    tester,
  ) async {
    await _pump(
      tester,
      TrackerContinueSection(
        // Same numbers, but nothing tells us how many aired — so the honest
        // answer is the fraction, not a guess.
        items: [_entry('Bleach', progress: 10, total: 10)],
        trackerName: 'MyAnimeList',
        onOpen: (_) {},
      ),
    );

    expect(find.text('EP 10/10'), findsOneWidget);
    expect(find.text('Caught up'), findsNothing);
  });

  testWidgets('NewEpisodesSection: overline tracker, next-episode badge', (
    tester,
  ) async {
    await _pump(
      tester,
      NewEpisodesSection(
        items: [_entry('Bleach', progress: 4, total: 24)],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );

    expect(find.text('New Episodes'), findsOneWidget);
    expect(find.text('AniList'), findsOneWidget); // the overline
    expect(find.text('EP 5'), findsOneWidget); // one past the progress
    expect(find.text('Bleach'), findsOneWidget);
    // 24 released, 4 seen — the count is what this row knows and the
    // continue rows don't.
    expect(find.text('+20'), findsOneWidget);
    // The whole point of the design: NOT the landscape card the two continue
    // rows use, so the row reads as a different thing while scrolling past.
    expect(find.byType(ContinueCard), findsNothing);
    expect(find.byType(PosterCard), findsOneWidget);
  });

  testWidgets('NewEpisodesSection counts only what has aired', (tester) async {
    await _pump(
      tester,
      NewEpisodesSection(
        // Still airing: episode 7 is next, so 6 are out and 2 are waiting —
        // counting against the 24-episode season would promise 20 that do
        // not exist yet.
        items: [_entry('Bleach', progress: 4, total: 24, nextAiring: 7)],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );

    expect(find.text('+2'), findsOneWidget);
    expect(find.text('EP 5'), findsOneWidget);
  });

  testWidgets('tracker rows offer See All; New Episodes deliberately does not', (
    tester,
  ) async {
    var continueSeeAll = 0;
    var bucketSeeAll = 0;
    await _pump(
      tester,
      Column(
        children: [
          TrackerContinueSection(
            items: [_entry('One Piece', progress: 4, total: 12)],
            trackerName: 'AniList',
            onOpen: (_) {},
            onSeeAll: () => continueSeeAll++,
          ),
          TrackerListSection(
            status: WatchStatus.planning,
            items: [_entry('Naruto', status: WatchStatus.planning)],
            trackerName: 'AniList',
            onOpen: (_) {},
            onSeeAll: () => bucketSeeAll++,
          ),
        ],
      ),
    );

    expect(find.text('See All'), findsNWidgets(2));
    await tester.tap(find.text('See All').first);
    await tester.tap(find.text('See All').last);
    expect(continueSeeAll, 1);
    expect(bucketSeeAll, 1);
  });

  testWidgets('New Episodes gets its own See All', (tester) async {
    var seen = 0;
    await _pump(
      tester,
      NewEpisodesSection(
        items: [_entry('Bleach', progress: 4, total: 24)],
        trackerName: 'AniList',
        onOpen: (_) {},
        onSeeAll: () => seen++,
      ),
    );

    await tester.tap(find.text('See All'));
    expect(seen, 1);
  });

  testWidgets('New Episodes without a handler draws no See All', (
    tester,
  ) async {
    await _pump(
      tester,
      NewEpisodesSection(
        items: [_entry('Bleach', progress: 4, total: 24)],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );
    expect(find.text('See All'), findsNothing);
  });

  testWidgets('every tracker row opens the info sheet on a long-press', (
    tester,
  ) async {
    // Poster rows on Home all do this; the tracker ones were the exception.
    final held = <String>[];
    await _pump(
      tester,
      Column(
        children: [
          TrackerContinueSection(
            items: [_entry('One Piece', progress: 4, total: 12)],
            trackerName: 'AniList',
            onOpen: (_) {},
            onLongPress: (e) => held.add(e.item.title),
          ),
          NewEpisodesSection(
            items: [_entry('Bleach', progress: 4, total: 24)],
            trackerName: 'AniList',
            onOpen: (_) {},
            onLongPress: (e) => held.add(e.item.title),
          ),
          TrackerListSection(
            status: WatchStatus.planning,
            items: [_entry('Naruto', status: WatchStatus.planning)],
            trackerName: 'AniList',
            onOpen: (_) {},
            onLongPress: (e) => held.add(e.item.title),
          ),
        ],
      ),
    );

    await tester.longPress(find.text('One Piece'));
    await tester.longPress(find.text('Bleach'));
    await tester.longPress(find.text('Naruto'));
    expect(held, ['One Piece', 'Bleach', 'Naruto']);
  });

  testWidgets('TrackerListSection keeps the anime labels', (tester) async {
    await _pump(
      tester,
      TrackerListSection(
        status: WatchStatus.watching,
        items: [_entry('Naruto')],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );
    expect(find.text('Watching'), findsOneWidget);
  });

  testWidgets('TrackerListSection relabels reading buckets', (tester) async {
    await _pump(
      tester,
      TrackerListSection(
        status: WatchStatus.planning,
        items: [_entry('Vagabond', type: ProviderType.manga)],
        trackerName: 'AniList',
        onOpen: (_) {},
      ),
    );
    expect(find.text('Plan to Read'), findsOneWidget);
  });

  testWidgets('empty sections render nothing at all', (tester) async {
    await _pump(
      tester,
      Column(
        children: [
          TrackerContinueSection(
            items: const [],
            trackerName: 'AniList',
            onOpen: (_) {},
          ),
          NewEpisodesSection(
            items: const [],
            trackerName: 'AniList',
            onOpen: (_) {},
          ),
          TrackerListSection(
            status: WatchStatus.watching,
            items: const [],
            trackerName: 'AniList',
            onOpen: (_) {},
          ),
        ],
      ),
    );

    expect(find.byType(SizedBox), findsWidgets); // only shrink boxes
    expect(find.textContaining('AniList'), findsNothing);
  });
}
