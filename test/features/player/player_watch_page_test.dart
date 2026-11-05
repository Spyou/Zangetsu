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
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
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

    await tester.tap(find.text('1. First Light'));
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

  testWidgets('autoplay switch reports the flipped value', (tester) async {
    bool? reported;
    await _pump(
      tester,
      _page(episodes: demoEpisodes, onAutoplayChanged: (v) => reported = v),
    );

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
    await _pump(
      tester,
      _page(
        episodes: const [
          WatchPageEpisode(
            index: 3,
            heading: '4. Not out yet',
            label: 'Not out yet',
            thumb: '',
            current: false,
            meta: 'Not out yet',
            unavailableReason: 'Not out yet',
          ),
        ],
        onOpenEpisode: (i) => opened = i,
      ),
    );

    expect(find.text('Not out yet'), findsOneWidget);
    await tester.tap(find.text('Not out yet'));
    expect(opened, isNull);
  });

  testWidgets('ambient follows the live frame', (tester) async {
    // 1x1 PNG. A real frame paints the gradient glow.
    final frame = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    await _pump(
      tester,
      _page(
        onOpenEpisode: (_) {},
        episodes: List.generate(
          20,
          (i) => WatchPageEpisode(
            index: i,
            heading: 'Episode ${i + 1}',
            label: 'Episode ${i + 1}',
            thumb: '',
            current: false,
          ),
        ),
        ambientFrameStream: Stream<Uint8List?>.value(frame),
      ),
    );
    // The frame decodes off the fake clock — give it real time.
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 1)));
    await tester.pumpAndSettle();

    final glow = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).gradient is RadialGradient,
    );
    expect(glow, findsOneWidget);
    expect(tester.getSize(glow).width, greaterThan(0));
    expect(tester.getSize(glow).height, greaterThan(0));
    final infoGlow = find.byKey(const ValueKey('ambient-info'));
    final videoGlow = find.byKey(const ValueKey('ambient-video'));
    final before = tester.getRect(infoGlow);
    final videoBefore = tester.getRect(videoGlow);
    expect(
      before.width,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
    );
    expect(
      before.bottom,
      greaterThan(tester.getBottomLeft(find.text('Comments')).dy),
    );
    expect(
      before.bottom,
      lessThanOrEqualTo(tester.getTopLeft(find.text('Episodes (20)')).dy),
    );

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(infoGlow).top, lessThan(before.top - 120));
    expect(tester.getRect(videoGlow), videoBefore);
    expect(tester.getSize(infoGlow).height, greaterThan(0));
    double opacity(String key) =>
        tester.widget<Opacity>(find.byKey(ValueKey(key))).opacity;
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
        .controller!;
    scroll.jumpTo(90);
    await tester.pump();
    expect(opacity('ambient-video-opacity'), closeTo(0.5, 0.01));
    expect(opacity('ambient-info-opacity'), closeTo(0.5, 0.01));
    scroll.jumpTo(180);
    await tester.pump();
    expect(opacity('ambient-video-opacity'), 0);
    expect(opacity('ambient-info-opacity'), 0);
    scroll.jumpTo(0);
    await tester.pump();
    expect(opacity('ambient-video-opacity'), 1);
    expect(opacity('ambient-info-opacity'), 1);
    expect(tester.takeException(), isNull);
  });
}
