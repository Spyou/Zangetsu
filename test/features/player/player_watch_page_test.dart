import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_watch_page.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/ui/frosted_surface.dart';
import 'package:watch_app/features/player/watch_page_motion.dart';
import 'package:watch_app/features/player/watch_page_info.dart';

PlayerWatchPage _page({
  bool isMovie = false,
  Stream<bool>? bufferingStream,
  String? description = 'A great episode.',
  String? nextTitle = 'The Next One',
  List<WatchPageEpisode> episodes = const [],
  void Function()? onServer,
  VoidCallback? onBack,
  VoidCallback? onTogglePlay,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onFullscreen,
  ValueChanged<Duration>? onSeek,
  void Function()? onComments,
  void Function(bool)? onAutoplayChanged,
  void Function(int)? onOpenEpisode,
  void Function(int, bool)? onSetWatched,
  void Function(int)? onPlayMirror,
  Widget Function(WatchPageEpisode)? downloadButton,
  Stream<Uint8List?>? ambientFrameStream,
  List<int>? seasons,
  int? selectedSeason,
  void Function(int?)? onSelectSeason,
}) {
  return PlayerWatchPage(
    isMovie: isMovie,
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
    bufferingStream: bufferingStream,
    ambientFrameStream: ambientFrameStream,
    nextThumb: null,
    nextLabel: 'S1 E2',
    nextTitle: nextTitle,
    autoplay: true,
    episodes: episodes,
    onTogglePlay: onTogglePlay ?? () {},
    onSeek: onSeek ?? (_) {},
    onPrevious: onPrevious ?? () {},
    onNext: onNext ?? () {},
    onFullscreen: onFullscreen ?? () {},
    onBack: onBack ?? () {},
    onServer: onServer ?? () {},
    onAudio: () {},
    onSubtitles: () {},
    onMore: () {},
    onOpenEpisode: onOpenEpisode ?? (_) {},
    onSetWatched: onSetWatched,
    onPlayMirror: onPlayMirror,
    downloadButton: downloadButton,
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

  testWidgets('movie keeps a playable row under a Movie heading', (
    tester,
  ) async {
    final opened = <int>[];
    await _pump(
      tester,
      _page(
        isMovie: true,
        nextTitle: null,
        episodes: const [
          WatchPageEpisode(
            index: 7,
            heading: 'Film title',
            label: 'Film title',
            thumb: '',
            current: false,
          ),
        ],
        onOpenEpisode: opened.add,
      ),
    );
    expect(find.text('Movie'), findsOneWidget);
    expect(find.text('Episodes (1)'), findsNothing);
    expect(find.byIcon(Icons.grid_view_rounded), findsNothing);
    await tester.ensureVisible(find.text('Film title'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Film title'));
    expect(opened, [7]);
  });

  testWidgets(
    'episode download button is separate from playback and synopsis is italic',
    (tester) async {
      final opened = <int>[];
      final downloaded = <int>[];
      await _pump(
        tester,
        _page(
          episodes: const [
            WatchPageEpisode(
              index: 8,
              heading: '9. Test',
              label: 'Test',
              thumb: '',
              current: false,
              synopsis: 'Episode synopsis',
            ),
          ],
          onOpenEpisode: opened.add,
          downloadButton: (ep) => IconButton(
            tooltip: 'Download episode',
            onPressed: () => downloaded.add(ep.index),
            icon: const Icon(Icons.download_rounded),
          ),
        ),
      );
      await tester.ensureVisible(find.byTooltip('Download episode'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download episode'));
      expect(downloaded, [8]);
      expect(opened, isEmpty);
      expect(
        tester.widget<Text>(find.text('Episode synopsis')).style?.fontStyle,
        FontStyle.italic,
      );
    },
  );

  testWidgets(
    'episode long press opens actions without playing and keeps its real index',
    (tester) async {
      final opened = <int>[];
      final marks = <(int, bool)>[];
      final mirrors = <int>[];
      await _pump(
        tester,
        _page(
          episodes: const [
            WatchPageEpisode(
              index: 17,
              heading: '18. Test episode',
              label: 'Test episode',
              thumb: '',
              current: false,
            ),
          ],
          onOpenEpisode: opened.add,
          onSetWatched: (i, w) => marks.add((i, w)),
          onPlayMirror: mirrors.add,
        ),
      );
      await tester.ensureVisible(find.text('18. Test episode'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('18. Test episode'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(marks, isEmpty);
      expect(find.text('Play mirror'), findsOneWidget);
      await tester.tap(find.text('Mark as watched'));
      await tester.pumpAndSettle();
      expect(marks, [(17, true)]);
      expect(opened, isEmpty);
      await tester.longPress(find.text('18. Test episode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play mirror'));
      await tester.pumpAndSettle();
      expect(mirrors, [17]);
      expect(opened, isEmpty);
      expect(
        find.ancestor(
          of: find.text('18. Test episode'),
          matching: find.byType(WatchPagePress),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('description grows smoothly while See less updates immediately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final description = List.filled(
      35,
      'A longer episode description.',
    ).join(' ');
    await _pump(tester, _page(description: description));
    await tester.pumpAndSettle();
    final card = find
        .ancestor(
          of: find.text(description),
          matching: find.byType(FrostedSurface),
        )
        .first;
    final collapsed = tester.getSize(card).height;
    await tester.ensureVisible(find.text('See more'));
    await tester.tap(find.text('See more'));
    await tester.pump();
    expect(find.text('See less'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 70));
    final during = tester.getSize(card).height;
    await tester.pumpAndSettle();
    final expanded = tester.getSize(card).height;
    expect(during, greaterThan(collapsed));
    expect(during, lessThan(expanded));
  });

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
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('watch-play')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('T'), findsOneWidget);
    expect(find.text('01:30 / 24:00'), findsOneWidget);
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
    expect(find.text('01:30 / 24:00'), findsOneWidget);
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
  for (final width in [320.0, 390.0, 600.0]) {
    testWidgets('portrait overlay layout at $width pixels', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, _page());
      await tester.pump();
      final video = tester.getRect(find.byKey(const ValueKey('watch-video')));
      final back = tester.getRect(find.byKey(const ValueKey('watch-back')));
      expect(back.top - video.top, 6);
      expect(back.left - video.left, 6);
      expect(back.size, const Size(48, 48));
      final play = tester.getRect(find.byKey(const ValueKey('watch-play')));
      expect(play.width, 56);
      expect(play.center.dx, closeTo(video.center.dx, 0.1));
      final seek = tester.getRect(find.byType(Slider));
      final time = tester.getRect(find.text('00:00 / 24:00'));
      expect(seek.width, greaterThan(video.width * 0.85));
      expect(seek.left - video.left, 16);
      expect(video.right - seek.right, 16);
      expect(time.top, greaterThanOrEqualTo(seek.bottom));
      expect(play.bottom, lessThanOrEqualTo(seek.top));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('portrait overlay keeps playback callbacks', (tester) async {
    var back = 0, play = 0, previous = 0, next = 0, fullscreen = 0;
    Duration? seek;
    await _pump(
      tester,
      _page(
        onBack: () => back++,
        onTogglePlay: () => play++,
        onPrevious: () => previous++,
        onNext: () => next++,
        onFullscreen: () => fullscreen++,
        onSeek: (value) => seek = value,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('watch-back')));
    await tester.tap(find.byKey(const ValueKey('watch-play')));
    await tester.tap(find.byIcon(Icons.skip_previous_rounded));
    await tester.tap(find.byIcon(Icons.skip_next_rounded));
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    tester.widget<Slider>(find.byType(Slider)).onChanged!(5000);
    expect([back, play, previous, next, fullscreen], [1, 1, 1, 1, 1]);
    expect(seek, const Duration(seconds: 5));
  });
  testWidgets(
    'buffering replaces Play with one loader, even with hidden controls',
    (tester) async {
      final buffering = StreamController<bool>();
      addTearDown(buffering.close);
      var played = 0;
      await _pump(
        tester,
        _page(bufferingStream: buffering.stream, onTogglePlay: () => played++),
      );
      await tester.pump();
      buffering.add(true);
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      final play = find.byKey(const ValueKey('watch-play'));
      expect(
        find.descendant(
          of: play,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      await tester.tap(play);
      expect(played, 0);
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('watch-video'))) +
            const Offset(120, 12),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find
                  .ancestor(of: play, matching: find.byType(AnimatedOpacity))
                  .first,
            )
            .opacity,
        1,
      );
      buffering.add(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('watch-video'))) +
            const Offset(120, 12),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(play);
      expect(played, 1);
    },
  );
  testWidgets(
    'shared loading-screen button has compact visuals and a large touch area',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: WatchPlayerButton(
              key: const ValueKey('shared-back'),
              icon: Icons.arrow_back_ios_new_rounded,
              label: 'Back',
              size: 32,
              iconSize: 18,
              onTap: () {},
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('shared-back'));
      expect(tester.getSize(button), const Size(48, 48));
      final circle = find.descendant(
        of: button,
        matching: find.byType(Container),
      );
      expect(tester.getSize(circle), const Size(32, 32));
      expect(
        (tester.widget<Container>(circle).decoration as BoxDecoration).color,
        Colors.black.withValues(alpha: 0.5),
      );
    },
  );
  testWidgets(
    'portrait actions scroll to the screen edges without an inset cutoff',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var opened = 0;
      await _pump(tester, _page(onServer: () => opened++));
      await tester.pump();
      final actions = find.ancestor(
        of: find.byIcon(Icons.dns_outlined),
        matching: find.byType(SingleChildScrollView),
      );
      final viewport = tester.getRect(actions);
      expect(viewport.left, 0);
      expect(viewport.right, 320);
      final before = tester.getRect(find.byIcon(Icons.dns_outlined));
      await tester.timedDrag(
        actions,
        const Offset(-20, 0),
        const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byIcon(Icons.dns_outlined)).left,
        lessThan(before.left),
      );
      await tester.tap(find.text('Server'));
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('mini-player seek bar uses the app accent', (tester) async {
    await _pump(tester, _page());
    final theme = SliderTheme.of(tester.element(find.byType(Slider)));
    expect(theme.activeTrackColor, AppColors.accent);
    expect(theme.thumbColor, AppColors.accent);
  });
}
