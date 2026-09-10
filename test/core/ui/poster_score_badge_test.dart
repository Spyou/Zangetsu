import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'dart:io';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/ui/poster_card.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('poster_score');
    Hive.init(dir.path);
    await Hive.openBox(PlaybackPrefs.boxName);
    GetIt.I.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  });

  tearDown(() async {
    await GetIt.I.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('a catalogue score shows on the poster', (tester) async {
    await tester.pumpWidget(_wrap(const PosterCard(title: 'X', scoreBadge: 86)));
    await tester.pump();
    // Carried 0-100, shown out of 10 — that is how a rating reads.
    expect(find.text('8.6'), findsOneWidget);
    expect(find.text('86'), findsNothing);
    // A star, because "8.6" alone reads as an episode count or a year.
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
  });

  testWidgets('no score, no badge — which is what keeps it off source posters', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const PosterCard(title: 'X')));
    await tester.pump();
    expect(find.byIcon(Icons.star_rounded), findsNothing);
  });

  testWidgets('it rides the existing Poster badges switch', (tester) async {
    await tester.pumpWidget(_wrap(const PosterCard(title: 'X', scoreBadge: 86)));
    await tester.pump();
    expect(find.text('8.6'), findsOneWidget);

    // runAsync: this writes to Hive, and a real write left dangling under
    // FakeAsync never completes — tearDown's Hive.close() then hangs the run.
    await tester.runAsync(
      () => GetIt.I<PlaybackPrefs>().setQualityBadges(false),
    );
    await tester.pump();
    expect(
      find.text('8.6'),
      findsNothing,
      reason: 'one switch covers every poster badge, not one per kind',
    );
  });

  testWidgets('quality wins the corner they share', (tester) async {
    // A poster has a resolution or a score, never both — but if a row ever
    // carried the two, overlapping chips would be the visible bug.
    await tester.pumpWidget(
      _wrap(const PosterCard(title: 'X', scoreBadge: 86, qualityBadge: '1080p')),
    );
    await tester.pump();
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('8.6'), findsNothing);
  });

  test('copyWith carries the score', () {
    // It lists fields by hand, and was already dropping genres and status —
    // a re-pointed row must not quietly lose its rating too.
    const item = MediaItem(
      id: 'a',
      title: 'A',
      url: 'u',
      type: ProviderType.anime,
      sourceId: 's',
      score: 86,
      genres: ['Action'],
    );
    final copy = item.copyWith(sourceId: 'other');
    expect(copy.score, 86);
    expect(copy.genres, ['Action']);
  });
}
