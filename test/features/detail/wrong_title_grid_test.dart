import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/ui/reveal_item.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/ui/states.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';

import '../../support/picker_deps.dart';

/// Two results with the SAME title and different covers — the case the grid
/// exists for. A list spends its width on text that is identical twice over.
class _Src implements SourceRepository {
  /// Mutable so a test can choose its results AFTER setUp — the Hive opens
  /// have to happen there, outside the FakeAsync zone testWidgets runs in,
  /// or they never complete.
  List<MediaItem> results = const [];
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'ani:1', name: 'AllAnime'),
  ];
  @override
  String baseUrlFor(String id) => 'https://example.test';
  @override
  bool hasSource(String sourceId) => true;
  @override
  String displayName(String id) => 'AllAnime';
  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async => results;
}

MediaItem _hit(String id) => MediaItem(
  id: id,
  title: 'Paradise Hotel',
  url: 'https://a/$id',
  type: ProviderType.anime,
  sourceId: 'ani:1',
);

void main() {
  late Directory dir;
  const c = ZCanonical(ZKind.anime, 'mal:5114');

  late _Src src;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongtitlegrid');
    Hive.init(dir.path);
    await registerPickerDeps(aniyomi: [aniSource(id: 1, name: 'AllAnime')]);
    for (final ch in const ['zangetsu/aniyomi', 'zangetsu/mihon']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(ch),
            (call) async => call.method == 'hasSourceSettings' ? false : null,
          );
    }
    src = _Src();
    final store = await MatchStore.open();
    final prefs = await ZSourcePrefs.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(
      SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => src.loadedSources,
      ),
    );
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  /// Opens the sheet directly rather than through MatchLine — this is about
  /// what the sheet renders, not how it is reached.
  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showWrongTitleSheet(
                ctx,
                canonical: c,
                title: 'Paradise Hotel',
                sourceId: 'ani:1',
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    // NOT pumpAndSettle: the loading state draws SkeletonGrid, whose shimmer
    // repeats forever, so "settled" never arrives.
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('results are a 3-up poster grid, not one row each', (t) async {
    src.results = [_hit('a'), _hit('b')];
    await open(t);

    expect(find.byType(PosterCard), findsNWidgets(2));
    // The cover used to be a bare Image.network with a width and no height,
    // which overflowed its row and clipped. Going through PosterCard is what
    // removes that whole class of bug.
    expect(find.byType(ListTile), findsNothing);
    final grid = t.widget<GridView>(find.byType(GridView));
    final d = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(d.crossAxisCount, 3, reason: 'same as the Search screen grid');
    expect(d.crossAxisSpacing, 12);
    expect(d.mainAxisSpacing, 16);
  });

  testWidgets('posters get the staggered reveal My List uses', (t) async {
    src.results = [_hit('a'), _hit('b')];
    await open(t);

    // Wrapped per item and keyed by index — that index is what staggers the
    // cascade, so passing a constant would silently flatten it.
    final reveals = t
        .widgetList<RevealItem>(find.byType(RevealItem))
        .toList(growable: false);
    expect(reveals.length, 2);
    expect([for (final r in reveals) r.index], [0, 1]);
  });

  testWidgets('on TV every poster is D-pad focusable', (t) async {
    // PosterCard is a bare GestureDetector; the ListTile this grid replaced
    // was focusable for free. TV's Detail screen shows "Wrong title?", so
    // without the wrapper the sheet opens and nothing can be selected.
    sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    src.results = [_hit('a'), _hit('b')];
    await open(t);

    expect(find.byType(TvFocusable), findsNWidgets(2));
    // The focusable owns OK, so the card must not also claim the tap.
    for (final p in t.widgetList<PosterCard>(find.byType(PosterCard))) {
      expect(p.onTap, isNull);
    }
  });

  testWidgets('on phone the poster keeps its own tap', (t) async {
    src.results = [_hit('a')];
    await open(t);

    expect(find.byType(TvFocusable), findsNothing);
    expect(t.widget<PosterCard>(find.byType(PosterCard)).onTap, isNotNull);
  });

  testWidgets('only the already-pinned result is marked CURRENT', (t) async {
    src.results = [_hit('a'), _hit('b')];
    await t.runAsync(
      () => sl<MatchStore>().pin(
        c,
        const SourceMatch(
          sourceId: 'ani:1',
          showUrl: 'https://a/b',
          showId: 'b',
          showTitle: 'Paradise Hotel',
          pinned: true,
        ),
      ),
    );
    await open(t);

    final cards = t
        .widgetList<PosterCard>(find.byType(PosterCard))
        .toList(growable: false);
    expect(cards.length, 2);
    // Marked by url, not by index or title: every result here shares a title,
    // which is exactly why the badge is needed.
    final marked = [for (final p in cards) p.tags.isNotEmpty];
    expect(marked, [false, true]);
    expect(find.text('CURRENT'), findsOneWidget);
  });

  testWidgets('no results shows an empty state, not a blank sheet', (t) async {
    src.results = const [];
    await open(t);

    // The old sheet drew an empty ListView here, which looked exactly like a
    // search still running.
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.text('Choose a source'), findsOneWidget);
  });

  testWidgets('the pre-filled query can be cleared in one tap', (t) async {
    src.results = [_hit('a')];
    await open(t);

    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      'Paradise Hotel',
    );
    await t.tap(find.byIcon(Icons.close_rounded));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '');
  });
}
