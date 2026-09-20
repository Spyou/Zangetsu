import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/ui/source_icon_tile.dart';
import 'package:watch_app/features/search/browse_sources_list.dart';

import '../../support/picker_deps.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('browse_list');
    Hive.init(dir.path);
    await registerPickerDeps(
      aniyomi: [aniSource(id: 1, name: 'HiAnime')],
    );
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('lists installed sources and reports the one tapped', (t) async {
    String? tappedId;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseSourcesList(onBrowse: (id, _) => tappedId = id),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsOneWidget);

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();
    expect(tappedId, 'ani:1');
  });

  // This list is the Sources TAB, so the shell's floating dock is drawn over
  // it and its height reaches the list as a bottom inset. A ListView with an
  // explicit padding opts out of absorbing that, so the padding has to add it
  // back — otherwise the last source sits under the dock with no way to
  // scroll it clear.
  testWidgets('the list clears the dock inset', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(bottom: 104)),
            child: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final list = t.widget<ListView>(find.byType(ListView).first);
    expect(
      (list.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(104.0),
      reason: 'the last source must scroll clear of the dock',
    );
  });

  // Sources are not all present when this screen first builds — CloudStream
  // plugins load from disk seconds after launch. The list used to read them
  // once and keep that answer, so a source that arrived later stayed invisible
  // until something forced a rebuild; switching tabs and back was the only way
  // to see it.
  testWidgets('a source that arrives after the first build shows up', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('AllAnime'), findsNothing);

    // What a late extension load does: register, then announce.
    sl<AniyomiManager>().registerAll([aniSource(id: 2, name: 'AllAnime')]);
    await t.pumpAndSettle();

    expect(find.textContaining('AllAnime'), findsOneWidget);
  });

  testWidgets('says so when nothing is installed', (t) async {
    await sl.reset();
    await registerPickerDeps();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsNothing);
    expect(find.text('No sources installed'), findsOneWidget);
  });

  testWidgets('query narrows the rows by source name', (t) async {
    await sl.reset();
    await registerPickerDeps(
      aniyomi: [
        aniSource(id: 1, name: 'HiAnime'),
        aniSource(id: 2, name: 'AllAnime'),
      ],
    );
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {}, query: 'hi')),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsOneWidget);
    expect(find.textContaining('AllAnime'), findsNothing);
  });

  testWidgets('a query nothing matches shows the no-matches state, not '
      'the nothing-installed one', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseSourcesList(onBrowse: (_, _) {}, query: 'zzz-nope'),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsNothing);
    expect(find.text('No matches found'), findsOneWidget);
    expect(find.text('No sources installed'), findsNothing);
  });

  testWidgets('every row carries a source icon tile', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // This list and the picker show the same sources; a row here without a
    // logo while the picker has one is exactly the drift the shared tile
    // exists to stop.
    expect(find.byType(SourceIconTile), findsWidgets);
  });

  testWidgets('streaming is one list — no ANIME / MOVIES & SERIES headers',
      (t) async {
    await disposePickerDeps();
    await sl.reset();
    await registerPickerDeps(aniyomi: [
      aniSource(id: 1, name: 'Zeta'),
      aniSource(id: 2, name: 'Alpha'),
    ]);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // Splitting by manifest type filed the same kind of source under two
    // different headers and made an A-Z rail meaningless.
    expect(find.text('ANIME'), findsNothing);
    expect(find.text('MOVIES & SERIES'), findsNothing);
  });

  testWidgets('rows are alphabetical by the source name, not the tag',
      (t) async {
    await disposePickerDeps();
    await sl.reset();
    await registerPickerDeps(aniyomi: [aniSource(id: 1, name: 'Zeta')]);
    // Two DIFFERENT tags on purpose. With one ecosystem the two orderings
    // agree and the test proves nothing: "Ani · Alpha" sorts before
    // "Ani · Zeta" either way. Across ecosystems they disagree — by raw label
    // "Ani · Zeta" beats "CS · Alpha", by name Alpha beats Zeta.
    sl<CloudStreamManager>().rebuildFromForTest([
      {
        'name': 'Alpha',
        'lang': 'en',
        'types': ['Anime'],
        'sourcePlugin': 'alpha@1',
      },
    ]);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    final alpha = t.getTopLeft(find.text('CS · Alpha')).dy;
    final zeta = t.getTopLeft(find.text('Ani · Zeta')).dy;
    expect(alpha, lessThan(zeta));
  });

  testWidgets('no A-Z rail on a short list', (t) async {
    await disposePickerDeps();
    await sl.reset();
    await registerPickerDeps(
      aniyomi: [aniSource(id: 1, name: 'Only One')],
    );

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // A rail over three rows is clutter; the whole list is already on screen.
    expect(find.byKey(alphabetRailKey), findsNothing);
  });

  testWidgets('a long list gets the A-Z rail, and tapping it scrolls',
      (t) async {
    await disposePickerDeps();
    await sl.reset();
    await registerPickerDeps(aniyomi: [
      for (var i = 0; i < 20; i++)
        aniSource(id: i + 1, name: String.fromCharCode(65 + i)),
    ]);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(find.byKey(alphabetRailKey), findsOneWidget);

    final list = find.byType(Scrollable).first;
    expect(t.widget<Scrollable>(list).controller!.offset, 0);

    // Press near the bottom of the rail — that is a late letter, so the list
    // must move. This is the whole point of the rail.
    final rail = t.getRect(find.byKey(alphabetRailKey));
    await t.tapAt(Offset(rail.center.dx, rail.bottom - 4));
    await t.pumpAndSettle();

    expect(t.widget<Scrollable>(list).controller!.offset, greaterThan(0));
  });

  testWidgets('a name starting with an emoji buckets under # at the TOP',
      (t) async {
    await disposePickerDeps();
    await sl.reset();
    await registerPickerDeps(aniyomi: [aniSource(id: 1, name: 'Alpha')]);
    sl<CloudStreamManager>().rebuildFromForTest([
      {
        'name': '⚡SportzX',
        'lang': 'en',
        'types': ['Anime'],
        'sourcePlugin': 'sportzx@1',
      },
    ]);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    // U+26A1 sorts ABOVE 'z', so a plain name-sort dropped this row at the
    // very bottom while the rail still bucketed it as '#' near the top —
    // '#' in two places, and the rail could only reach the first.
    final emoji = t.getTopLeft(find.text('CS · ⚡SportzX')).dy;
    final alpha = t.getTopLeft(find.text('Ani · Alpha')).dy;
    expect(emoji, lessThan(alpha));
  });

  test('sourceInitial buckets by the source name, not the tag', () {
    expect(sourceInitial('CS · Vidsrc'), 'V');
    expect(sourceInitial('Ani · AnimePahe'), 'A');
    expect(sourceInitial('4K HDHub'), '#');
    expect(sourceInitial('CS · ⚡SportzX'), '#');
    expect(sourceInitial(''), '#');
  });

  testWidgets('rail letters get equal slots, not gaps stretched to fill',
      (t) async {
    await disposePickerDeps();
    await sl.reset();
    await registerPickerDeps(aniyomi: [
      for (var i = 0; i < 20; i++)
        aniSource(id: i + 1, name: String.fromCharCode(65 + i)),
    ]);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    final railH = t.getSize(find.byKey(alphabetRailKey)).height;
    final listH = t.getSize(find.byType(BrowseSourcesList)).height;

    // 20 letters at a fixed slot each — NOT spread over the whole list, which
    // made the gaps depend on how many letters there happened to be.
    expect(railH, 20 * railSlotHeight);
    expect(railH, lessThan(listH));

    // And centred in the list, not pinned to the top.
    final rail = t.getRect(find.byKey(alphabetRailKey));
    final list = t.getRect(find.byType(BrowseSourcesList));
    expect((rail.center.dy - list.center.dy).abs(), lessThan(24));
  });

  testWidgets('a finger on the rail shows a small letter preview beside it',
      (t) async {
    await disposePickerDeps();
    await sl.reset();
    await registerPickerDeps(aniyomi: [
      for (var i = 0; i < 20; i++)
        aniSource(id: i + 1, name: String.fromCharCode(65 + i)),
    ]);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(find.byKey(railPreviewKey), findsNothing);

    // Hold, don't tap: the preview only exists while a finger is down.
    final rail = t.getRect(find.byKey(alphabetRailKey));
    final g = await t.startGesture(Offset(rail.center.dx, rail.top + 4));
    await t.pump(const Duration(milliseconds: 250));

    expect(find.byKey(railPreviewKey), findsOneWidget);
    final preview = t.getRect(find.byKey(railPreviewKey));
    final listRect = t.getRect(find.byType(BrowseSourcesList));
    // Beside the rail on the right, not floating in the middle of the list.
    expect(preview.center.dx, greaterThan(listRect.center.dx));
    expect(preview.right, lessThanOrEqualTo(rail.left + 1));
    // And it rides the letter: near the top of the rail, so near the top row.
    expect(preview.center.dy, lessThan(listRect.center.dy));
    // Small — the slider letters carry the motion, not this.
    expect(preview.width, lessThanOrEqualTo(48));

    await g.up();
    await t.pumpAndSettle();
    expect(find.byKey(railPreviewKey), findsNothing);
  });
}
