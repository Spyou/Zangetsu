import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_watch_page.dart';
import 'package:watch_app/features/player/watch_page_info.dart';

PlayerWatchPage _page({
  String? description = 'A great episode.',
  String? nextTitle = 'The Next One',
  List<WatchPageEpisode> episodes = const [],
  void Function()? onServer,
  void Function()? onComments,
  void Function(bool)? onAutoplayChanged,
  void Function(int)? onOpenEpisode,
  Stream<Uint8List?>? ambientFrameStream,
  List<int>? seasons,
  int? selectedSeason,
  void Function(int?)? onSelectSeason,
}) {
  return PlayerWatchPage(
    video: const ColoredBox(color: Colors.black),
    header: WatchPageHeader(
      title: 'The Fall',
      subtitle: 'Show · S1 E1',
      description: description,
    ),
    positionStream: Stream.value(Duration.zero),
    durationStream: Stream.value(const Duration(minutes: 24)),
    playingStream: Stream.value(false),
    initialPlaying: false,
    initialPosition: Duration.zero,
    initialDuration: Duration.zero,
    hasPrevious: true,
    ambientFrameStream: ambientFrameStream,
    nextThumb: null,
    nextLabel: 'S1 E2',
    nextTitle: nextTitle,
    autoplay: true,
    episodes: episodes,
    onTogglePlay: () {},
    onSeek: (_) {},
    onPrevious: () {},
    onNext: () {},
    onFullscreen: () {},
    onBack: () {},
    onServer: onServer ?? () {},
    onAudio: () {},
    onSubtitles: () {},
    onMore: () {},
    onOpenEpisode: onOpenEpisode ?? (_) {},
    seasons: seasons,
    selectedSeason: selectedSeason,
    onSelectSeason: onSelectSeason,
    onComments: onComments ?? () {},
    onAutoplayChanged: onAutoplayChanged ?? (_) {},
  );
}

Future<void> _pump(WidgetTester tester, PlayerWatchPage page) {
  return tester.pumpWidget(MaterialApp(home: page));
}

void main() {
  const demoEpisodes = [
    WatchPageEpisode(
      index: 0,
      heading: '1. First Light',
      label: 'First Light',
      thumb: '',
      current: false,
      meta: '24 min',
      synopsis: 'Light rises.',
    ),
    WatchPageEpisode(
      index: 1,
      heading: 'Episode 2',
      label: 'Episode 2',
      thumb: '',
      current: true,
    ),
  ];

  testWidgets('shows title, actions, description and episodes', (tester) async {
    await _pump(tester, _page(episodes: demoEpisodes, nextTitle: 'Episode 2'));

    // Auto-scroll lands on the current row; go back up for the top.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('The Fall'), findsOneWidget);
    expect(find.text('1. First Light'), findsOneWidget);
    expect(find.text('24 min'), findsOneWidget);
    expect(find.text('Light rises.'), findsOneWidget);
    expect(find.text('Show · S1 E1'), findsOneWidget);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('A great episode.'), findsOneWidget);
    expect(find.text('Comments'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget);
    // No separate Up Next section — the list is the up-next.
    expect(find.text('Up next'), findsNothing);
    expect(find.text('Episodes (2)'), findsOneWidget);
    // Scroll down to the current row.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    // No fake engagement anywhere.
    expect(find.textContaining('41.9k'), findsNothing);
    expect(find.textContaining('37'), findsNothing);
  });

  testWidgets('hides description and empty list gracefully', (tester) async {
    await _pump(tester, _page(description: null, nextTitle: null));

    expect(find.text('Comments'), findsOneWidget);
    expect(find.text('The Next One'), findsNothing);
    expect(find.text('1. First Light'), findsNothing);
    expect(find.textContaining('Episodes'), findsNothing);
  });

  testWidgets('tapping an episode row opens that index', (tester) async {
    int? opened;
    await _pump(
      tester,
      _page(
        onOpenEpisode: (i) => opened = i,
        episodes: const [
          WatchPageEpisode(
            index: 0,
            heading: '1. A',
            label: 'A',
            thumb: '',
            current: true,
          ),
          WatchPageEpisode(
            index: 5,
            heading: '5. F',
            label: 'F',
            thumb: '',
            current: false,
          ),
        ],
      ),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5. F'));
    expect(opened, 5);
  });

  testWidgets('season pill opens the sheet and picks a season', (tester) async {
    int? picked;
    await _pump(
      tester,
      _page(
        onOpenEpisode: (_) {},
        episodes: const [
          WatchPageEpisode(
            index: 0,
            heading: '1. A',
            label: 'A',
            thumb: '',
            current: true,
          ),
          WatchPageEpisode(
            index: 5,
            heading: '2. B',
            label: 'B',
            thumb: '',
            current: false,
          ),
        ],
        seasons: const [1, 2],
        selectedSeason: 1,
        onSelectSeason: (s) => picked = s,
      ),
    );

    // The pill mirrors the detail screen's season selector.
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season 2').last);
    await tester.pumpAndSettle();
    expect(picked, 2);
  });

  testWidgets('range chips page long lists', (tester) async {
    await _pump(
      tester,
      _page(
        onOpenEpisode: (_) {},
        episodes: List.generate(
          60,
          (i) => WatchPageEpisode(
            index: i,
            heading: 'Episode ${i + 1}',
            label: 'Episode ${i + 1}',
            thumb: '',
            current: false,
            number: i + 1,
          ),
        ),
      ),
    );

    // Bring the header into the viewport first.
    expect(find.byType(CustomScrollView), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('watch_ranges')));
    await tester.pumpAndSettle();
    expect(find.text('1\u201350'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('watch_ranges'))).height,
      32,
    );
    await tester.drag(
      find.byKey(const ValueKey('watch_ranges')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('51\u201360'));
    await tester.pumpAndSettle();
    // Second page starts at EP 51.
    expect(find.text('Episode 51'), findsOneWidget);
    expect(find.text('Episode 1'), findsNothing);
  });

  testWidgets('reverse flips the rows but keeps real indices', (tester) async {
    int? opened;
    await _pump(
      tester,
      _page(
        onOpenEpisode: (i) => opened = i,
        episodes: const [
          WatchPageEpisode(
            index: 0,
            heading: '1. A',
            label: 'A',
            thumb: '',
            current: false,
          ),
          WatchPageEpisode(
            index: 1,
            heading: '2. B',
            label: 'B',
            thumb: '',
            current: false,
          ),
        ],
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reverse order'));
    await tester.pumpAndSettle();
    // Reversed list puts EP 1 at the bottom — scroll to it.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. A').first);
    expect(opened, 0);
  });

  testWidgets('server and comments taps reach the parent', (tester) async {
    var server = 0;
    var comments = 0;
    await _pump(
      tester,
      _page(onServer: () => server++, onComments: () => comments++),
    );

    await tester.tap(find.text('Server'));
    await tester.tap(find.text('Comments'));
    expect(server, 1);
    expect(comments, 1);
  });

  testWidgets('autoplay in More reports the flipped value', (tester) async {
    bool? reported;
    await _pump(
      tester,
      _page(episodes: demoEpisodes, onAutoplayChanged: (v) => reported = v),
    );

    expect(find.text('Auto-play'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto-play'));
    await tester.pumpAndSettle();
    expect(reported, isFalse);
  });

  testWidgets('loading shows a spinner inside the mini player', (tester) async {
    await _pump(
      tester,
      PlayerWatchPage(
        video: const ColoredBox(color: Colors.black),
        header: const WatchPageHeader(
          title: 'T',
          subtitle: 'S',
          description: null,
        ),
        loading: true,
        positionStream: Stream<Duration>.empty(),
        durationStream: Stream<Duration?>.empty(),
        playingStream: Stream.value(false),
        initialPlaying: false,
        initialPosition: const Duration(minutes: 1, seconds: 30),
        initialDuration: const Duration(minutes: 24),
        hasPrevious: false,
        nextThumb: null,
        nextLabel: null,
        nextTitle: null,
        autoplay: true,
        episodes: const [],
        onOpenEpisode: (_) {},
        onTogglePlay: () {},
        onSeek: (_) {},
        onPrevious: () {},
        onNext: () {},
        onFullscreen: () {},
        onBack: () {},
        onServer: () {},
        onAudio: () {},
        onSubtitles: () {},
        onMore: () {},
        onComments: () {},
        onAutoplayChanged: (_) {},
      ),
    );

    // The page stays — title and times visible under the spinner.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Finding the best source…'), findsOneWidget);
    expect(find.text('T'), findsOneWidget);
    expect(find.text('01:30'), findsOneWidget);
  });

  testWidgets('shows the live position before the first stream tick', (
    tester,
  ) async {
    await _pump(
      tester,
      PlayerWatchPage(
        video: const ColoredBox(color: Colors.black),
        header: const WatchPageHeader(
          title: 'T',
          subtitle: 'S',
          description: null,
        ),
        positionStream: Stream<Duration>.empty(),
        durationStream: Stream<Duration?>.empty(),
        playingStream: Stream.value(false),
        initialPlaying: false,
        initialPosition: const Duration(minutes: 1, seconds: 30),
        initialDuration: const Duration(minutes: 24),
        hasPrevious: false,
        nextThumb: null,
        nextLabel: null,
        nextTitle: null,
        autoplay: true,
        episodes: const [],
        onOpenEpisode: (_) {},
        onTogglePlay: () {},
        onSeek: (_) {},
        onPrevious: () {},
        onNext: () {},
        onFullscreen: () {},
        onBack: () {},
        onServer: () {},
        onAudio: () {},
        onSubtitles: () {},
        onMore: () {},
        onComments: () {},
        onAutoplayChanged: (_) {},
      ),
    );

    // Silent streams must not read 00:00 — the handoff carries the values.
    expect(find.text('01:30'), findsOneWidget);
    expect(find.text('24:00'), findsOneWidget);
  });

  testWidgets('spinner stays up until the first frame, loading or not', (
    tester,
  ) async {
    await _pump(
      tester,
      PlayerWatchPage(
        video: const ColoredBox(color: Colors.black),
        header: const WatchPageHeader(
          title: 'T',
          subtitle: 'S',
          description: null,
        ),
        loading: false,
        firstFrameStream: Stream<int?>.empty(),
        initialFirstFrame: 0,
        positionStream: Stream<Duration>.empty(),
        durationStream: Stream<Duration?>.empty(),
        playingStream: Stream.value(false),
        initialPlaying: false,
        initialPosition: Duration.zero,
        initialDuration: Duration.zero,
        hasPrevious: false,
        nextThumb: null,
        nextLabel: null,
        nextTitle: null,
        autoplay: true,
        episodes: const [],
        onOpenEpisode: (_) {},
        onTogglePlay: () {},
        onSeek: (_) {},
        onPrevious: () {},
        onNext: () {},
        onFullscreen: () {},
        onBack: () {},
        onServer: () {},
        onAudio: () {},
        onSubtitles: () {},
        onMore: () {},
        onComments: () {},
        onAutoplayChanged: (_) {},
      ),
    );

    // No picture yet — the spinner holds even though nothing is "loading".
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('dead rows show their reason and ignore taps', (tester) async {
    int? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerWatchPage(
          video: const ColoredBox(color: Colors.black),
          header: const WatchPageHeader(
            title: 'T',
            subtitle: 'S',
            description: null,
          ),
          positionStream: Stream<Duration>.empty(),
          durationStream: Stream<Duration?>.empty(),
          playingStream: Stream.value(false),
          initialPlaying: false,
          initialPosition: Duration.zero,
          initialDuration: Duration.zero,
          hasPrevious: false,
          autoplay: true,
          episodes: const [
            WatchPageEpisode(
              index: 3,
              heading: '4. X',
              label: 'X',
              thumb: '',
              current: false,
              meta: 'Not out yet',
              unavailableReason: 'Not out yet',
            ),
          ],
          onOpenEpisode: (i) => opened = i,
          onTogglePlay: () {},
          onSeek: (_) {},
          onPrevious: () {},
          onNext: () {},
          onFullscreen: () {},
          onBack: () {},
          onServer: () {},
          onAudio: () {},
          onSubtitles: () {},
          onMore: () {},
          onComments: () {},
          onAutoplayChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Not out yet'), findsOneWidget);
    await tester.tap(find.text('Not out yet'));
    expect(opened, isNull);
  });

  testWidgets('ambient follows the live frame', (tester) async {
    // 1x1 PNG. A decoded frame paints the wash.
    final frame = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    await _pump(
      tester,
      _page(
        onOpenEpisode: (_) {},
        episodes: const [],
        ambientFrameStream: Stream<Uint8List?>.value(frame),
      ),
    );
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 1)));
    await tester.pumpAndSettle();

    final wash = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).gradient is RadialGradient,
    );
    expect(wash, findsOneWidget);
  });

  testWidgets('grid toggle shows numbered tiles', (tester) async {
    int? opened;
    await _pump(
      tester,
      _page(
        onOpenEpisode: (i) => opened = i,
        episodes: const [
          WatchPageEpisode(
            index: 0,
            heading: '1. A',
            label: 'A',
            thumb: '',
            current: true,
          ),
          WatchPageEpisode(
            index: 1,
            heading: '2. B',
            label: 'B',
            thumb: '',
            current: false,
          ),
        ],
      ),
    );

    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
    await tester.tap(find.text('2').first);
    expect(opened, 1);
  });

  testWidgets('jump dialog scrolls to the typed episode', (tester) async {
    await _pump(
      tester,
      _page(
        onOpenEpisode: (_) {},
        episodes: List.generate(
          60,
          (i) => WatchPageEpisode(
            index: i,
            heading: 'Episode ${i + 1}',
            label: 'Episode ${i + 1}',
            thumb: '',
            current: false,
            number: i + 1,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '59');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('Episode 59'), findsOneWidget);
  });
  for (final (numbered, grid, reversed) in [
    (true, false, false),
    (false, false, false),
    (true, true, true),
    (false, false, true),
  ]) {
    testWidgets(
      'jump finds middle row: numbers=$numbered grid=$grid reverse=$reversed',
      (tester) async {
        int? opened;
        await _pump(
          tester,
          _page(
            onOpenEpisode: (index) => opened = index,
            episodes: List.generate(
              120,
              (i) => WatchPageEpisode(
                index: i + 200,
                heading: 'Episode ${i + 1}',
                label: 'Episode ${i + 1}',
                thumb: '',
                current: false,
                number: numbered ? i + 1 : null,
              ),
            ),
          ),
        );
        if (reversed) {
          await tester.tap(find.byIcon(Icons.more_vert_rounded));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Reverse order'));
          await tester.pumpAndSettle();
        }
        if (grid) {
          await tester.tap(find.byIcon(Icons.grid_view_rounded));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byIcon(Icons.search_rounded));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '75');
        await tester.tap(find.text('Go'));
        await tester.pumpAndSettle();
        final target = find.text(grid ? '75' : 'Episode 75');
        expect(target.hitTestable(), findsOneWidget);
        await tester.tap(target);
        expect(opened, 274);
      },
    );
  }
}
