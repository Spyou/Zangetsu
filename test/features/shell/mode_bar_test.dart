import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/shell/mode_bar.dart';

void main() {
  testWidgets('shows five choices and reports the pick', (t) async {
    ContentMode? mode;
    StreamKind? kind;
    await t.pumpWidget(MaterialApp(home: Scaffold(
      body: ModeBar(
        open: true,
        current: (ContentMode.anime, StreamKind.anime),
        sourcesSelected: false,
        onPicked: (m, k) { mode = m; kind = k; },
        onSourcesPicked: () {},
      ),
    )));
    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Movie/TV'), findsOneWidget);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.text('Novel'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    await t.tap(find.text('Movie/TV'));
    expect(mode, ContentMode.anime);
    expect(kind, StreamKind.movie);
    await t.tap(find.text('Manga'));
    expect(mode, ContentMode.manga);
  });

  testWidgets('closed bar ignores taps', (t) async {
    var picked = 0;
    await t.pumpWidget(MaterialApp(home: Scaffold(
      body: ModeBar(
        open: false,
        current: (ContentMode.anime, StreamKind.anime),
        sourcesSelected: false,
        onPicked: (_, _) => picked++,
        onSourcesPicked: () {},
      ),
    )));
    await t.tap(find.text('Manga'), warnIfMissed: false);
    expect(picked, 0);
  });

  testWidgets('Sources is a mode pick, not navigation', (t) async {
    var picked = 0;
    var sourcesPicked = 0;
    await t.pumpWidget(MaterialApp(home: Scaffold(
      body: ModeBar(
        open: true,
        current: (ContentMode.anime, StreamKind.anime),
        sourcesSelected: false,
        onPicked: (_, _) => picked++,
        onSourcesPicked: () => sourcesPicked++,
      ),
    )));

    expect(find.text('Sources'), findsOneWidget);
    await t.tap(find.text('Sources'));
    expect(sourcesPicked, 1);
    expect(picked, 0);
  });

  testWidgets(
    'Manga selected AND Sources on render active at the same time '
    '(the combination that is unreachable today)',
    (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(
        body: ModeBar(
          open: true,
          current: (ContentMode.manga, StreamKind.anime),
          sourcesSelected: true,
          onPicked: (_, _) {},
          onSourcesPicked: () {},
        ),
      )));

      final manga = t.widget<Text>(find.text('Manga'));
      final sources = t.widget<Text>(find.text('Sources'));

      // Manga stays the selected content mode — sourcesSelected doesn't
      // knock it out of the segmented group.
      expect(manga.style?.color, AppColors.accent);
      // Combined video entry ("Streaming") isn't selected here.
      final streaming = t.widget<Text>(find.text('Streaming'));
      expect(streaming.style?.color, isNot(AppColors.accent));
      // Sources renders its own independent "on" state at the same time.
      expect(sources.style?.color, isNot(streaming.style?.color));
    },
  );

  testWidgets('Sources off shows four content entries incl. Movie/TV', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(
      body: ModeBar(
        open: true,
        current: (ContentMode.anime, StreamKind.anime),
        sourcesSelected: false,
        onPicked: (_, _) {},
        onSourcesPicked: () {},
      ),
    )));

    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Movie/TV'), findsOneWidget);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.text('Novel'), findsOneWidget);
    expect(find.text('Streaming'), findsNothing);
  });

  testWidgets('Sources on collapses Anime/Movie-TV into one entry', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(
      body: ModeBar(
        open: true,
        current: (ContentMode.anime, StreamKind.anime),
        sourcesSelected: true,
        onPicked: (_, _) {},
        onSourcesPicked: () {},
      ),
    )));

    expect(find.text('Streaming'), findsOneWidget);
    expect(find.text('Anime'), findsNothing);
    expect(find.text('Movie/TV'), findsNothing);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.text('Novel'), findsOneWidget);
  });

  testWidgets(
    'Sources on: combined entry shows selected for anime mode regardless '
    'of StreamKind',
    (t) async {
      for (final kind in StreamKind.values) {
        await t.pumpWidget(MaterialApp(home: Scaffold(
          body: ModeBar(
            open: true,
            current: (ContentMode.anime, kind),
            sourcesSelected: true,
            onPicked: (_, _) {},
            onSourcesPicked: () {},
          ),
        )));

        final streaming = t.widget<Text>(find.text('Streaming'));
        expect(streaming.style?.color, AppColors.accent, reason: 'kind=$kind');
      }
    },
  );

  testWidgets(
    'toggling Sources leaves the picked content mode alone and vice versa',
    (t) async {
      var picked = 0;
      var sourcesPicked = 0;
      await t.pumpWidget(MaterialApp(home: Scaffold(
        body: ModeBar(
          open: true,
          current: (ContentMode.manga, StreamKind.anime),
          sourcesSelected: false,
          onPicked: (_, _) => picked++,
          onSourcesPicked: () => sourcesPicked++,
        ),
      )));

      await t.tap(find.text('Sources'));
      expect(sourcesPicked, 1);
      expect(picked, 0);

      await t.tap(find.text('Manga'));
      expect(picked, 1);
      expect(sourcesPicked, 1);
    },
  );
}
