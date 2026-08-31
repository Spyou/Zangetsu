import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
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
    'sourcesSelected renders Sources selected and the four content modes unselected',
    (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(
        body: ModeBar(
          open: true,
          current: (ContentMode.anime, StreamKind.anime),
          sourcesSelected: true,
          onPicked: (_, _) {},
          onSourcesPicked: () {},
        ),
      )));

      final sources = t.widget<Text>(find.text('Sources'));
      final anime = t.widget<Text>(find.text('Anime'));
      // Selected labels render in the accent colour; unselected in the
      // secondary one — see _Choice.build.
      expect(sources.style?.color, isNot(anime.style?.color));
    },
  );
}
