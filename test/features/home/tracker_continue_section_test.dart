import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
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
