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
    onOpenEpisode: (_) {},
    onComments: onComments ?? () {},
    onAutoplayChanged: onAutoplayChanged ?? (_) {},
  );
}

Future<void> _pump(WidgetTester tester, PlayerWatchPage page) {
  return tester.pumpWidget(MaterialApp(home: page));
}

void main() {
  const demoEpisodes = [
    WatchPageEpisode(index: 0, label: 'First Light', current: false),
    WatchPageEpisode(index: 1, label: 'Episode 2', current: true),
  ];

  testWidgets('shows title, actions, description, up next and episodes',
      (tester) async {
    await _pump(
      tester,
      _page(episodes: demoEpisodes, nextTitle: 'Episode 2'),
    );

    expect(find.text('The Fall'), findsOneWidget);
    expect(find.text('First Light'), findsOneWidget);
    expect(find.text('Show · S1 E1'), findsOneWidget);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('A great episode.'), findsOneWidget);
    expect(find.text('Comments'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    expect(find.text('Episodes (2)'), findsOneWidget);
    expect(find.text('Episode 2'), findsNWidgets(2)); // row + up-next card
    // No fake engagement anywhere.
    expect(find.textContaining('41.9k'), findsNothing);
    expect(find.textContaining('37'), findsNothing);
  });

  testWidgets('hides description and up next when there is nothing to show',
      (tester) async {
    await _pump(tester, _page(description: null, nextTitle: null));

    expect(find.text('Comments'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    expect(find.text('The Next One'), findsNothing);
    expect(find.text('First Light'), findsNothing);
  });

  testWidgets('tapping an episode row opens that index', (tester) async {
    int? opened;
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
        initialPosition: Duration.zero,
        initialDuration: Duration.zero,
        hasPrevious: false,
        nextThumb: null,
        nextLabel: null,
        nextTitle: null,
        autoplay: true,
        episodes: demoEpisodes,
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
    );

    await tester.tap(find.text('First Light'));
    expect(opened, 0);
  });

  testWidgets('server and comments taps reach the parent', (tester) async {
    var server = 0;
    var comments = 0;
    await _pump(
      tester,
      _page(
        onServer: () => server++,
        onComments: () => comments++,
      ),
    );

    await tester.tap(find.text('Server'));
    await tester.tap(find.text('Comments'));
    expect(server, 1);
    expect(comments, 1);
  });

  testWidgets('autoplay switch reports the flipped value', (tester) async {
    bool? reported;
    await _pump(tester, _page(onAutoplayChanged: (v) => reported = v));

    await tester.tap(find.byType(Switch));
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
}
