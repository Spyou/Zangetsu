import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/features/home/continue_section.dart';

HistoryEntry _row(String title, String showUrl) => HistoryEntry(
  sourceId: showUrl.startsWith('zm://') ? 'zm' : 'cs:HDHub4U',
  showId: title,
  showTitle: title,
  showUrl: showUrl,
  category: 'sub',
  episodeId: '1',
  episodeNumber: 1,
  episodeUrl: '$showUrl/ep/1',
  position: Duration.zero,
  duration: const Duration(minutes: 24),
  updatedAt: 0,
);

void main() {
  // ContinueCard asks AppMode whether it is on TV.
  setUp(() => sl.registerSingleton<AppMode>(const AppMode(isTv: false)));
  tearDown(() => sl.reset());

  testWidgets('Continue Watching is one list — anime, film and source rows '
      'all render together', (t) async {
    // It used to be filtered by Anime vs Movie/TV, which meant checking two
    // tabs to find where you were. Worse, the filter read the kind from the
    // SOURCE: rows are saved against the router ("zm"), a name no repo
    // manifest carries, so every row resolved to null and Movie/TV was empty.
    // Reading (manga/novel) is still its own row — a different store entirely.
    final history = [
      _row('Bleach', 'zm://anime/mal:41467'),
      _row('The Odyssey', 'zm://movie/tmdb:1108427'),
      _row('Reacher', 'zm://tv/tmdb:108978'),
      _row('Lanterns', 'https://new5.hdhub4u.cl/lanterns-season-1/'),
    ];

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ContinueWatchingRow(
                history: history,
                onSeeAll: () {},
                onResume: (_) {},
                onLongPress: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    // The cards carry a staggered reveal; let its timers fire or the binding
    // fails the test on a pending timer after the tree is disposed.
    await t.pump(const Duration(seconds: 2));

    for (final title in const [
      'Bleach',
      'The Odyssey',
      'Reacher',
      'Lanterns',
    ]) {
      expect(find.text(title), findsOneWidget, reason: '$title is missing');
    }
    await t.pump(const Duration(seconds: 2));
  });
}
