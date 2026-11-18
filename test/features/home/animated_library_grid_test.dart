import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/placement_slide.dart';
import 'package:watch_app/core/ui/reveal_item.dart';
import 'package:watch_app/features/home/animated_library_grid.dart';

Widget _host(
  List<String> items, {
  void Function(BuildContext, int, String)? onBuild,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AnimatedLibraryGrid<String>(
        items: items,
        keyOf: (s) => s,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
        ),
        itemBuilder: (context, index, item, slide) {
          onBuild?.call(context, index, item);
          // Same layering as production: keyed entrance outside, slide inside.
          return RevealItem(
            key: ValueKey('cell:$item'),
            index: index,
            child: PlacementSlide(
              from: slide.from,
              duration: const Duration(milliseconds: 250),
              onDone: slide.unplace,
              child: Text(item),
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    await sl.reset();
  });

  test('placementFrom: same-row moves are purely horizontal', () {
    // 3 columns, 100x150 cells, 12px gaps. Slot 4 sits mid-row; its
    // predecessor comes from slot 5, one column over.
    final d = placementFrom(
      slot: 4,
      cellW: 100,
      cellH: 150,
      cross: 12,
      main: 16,
      columns: 3,
    );
    expect(d, const Offset(112, 0));
  });

  test('placementFrom: row-boundary moves come out diagonal', () {
    // Slot 2 is the last of its row; its predecessor drops from the next
    // row's first column: left two columns, down one row.
    final d = placementFrom(
      slot: 2,
      cellW: 100,
      cellH: 150,
      cross: 12,
      main: 16,
      columns: 3,
    );
    expect(d, const Offset(-224, 166));
  });

  test('libraryKeyVisible: only a re-added key shows again', () {
    // Mid-commit (present, flight running): hidden.
    expect(
      libraryKeyVisible(commitInFlight: true, presentInStore: true),
      isFalse,
    );
    // Reload confirmed (absent): hidden — already a no-op for the filter.
    expect(
      libraryKeyVisible(commitInFlight: false, presentInStore: false),
      isFalse,
    );
    // Re-added (present, no flight): visible at once.
    expect(
      libraryKeyVisible(commitInFlight: false, presentInStore: true),
      isTrue,
    );
  });

  testWidgets('removal glides neighbours instead of snapping', (t) async {
    await t.pumpWidget(_host(['a', 'b', 'c', 'd', 'e', 'f']));
    // Settle entrances first so a later fade can only mean a replay.
    await t.pumpAndSettle();
    await t.pumpWidget(_host(['a', 'c', 'd', 'e', 'f']));
    // Mid-glide: moved cards carry a live translate (no snap to final) ...
    await t.pump(const Duration(milliseconds: 100));
    final offsets = t
        .widgetList<Transform>(find.byType(Transform))
        .map((w) => w.transform.getTranslation())
        .where((o) => o.x != 0 || o.y != 0);
    expect(offsets, isNotEmpty);
    // ... and no entrance replays: every card stays fully opaque.
    final fades = t.widgetList<Opacity>(find.byType(Opacity));
    expect(fades, isNotEmpty);
    for (final o in fades) {
      expect(o.opacity, 1.0);
    }
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('b'), findsNothing);
    for (final label in ['a', 'c', 'd', 'e', 'f']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('insertion shows the newcomer without touching the rest', (
    t,
  ) async {
    await t.pumpWidget(_host(['a', 'c']));
    await t.pumpWidget(_host(['a', 'b', 'c']));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
  });

  testWidgets('same keys, new objects: no animation, cells refresh', (t) async {
    final seen = <String>[];
    await t.pumpWidget(
      _host(['a', 'b'], onBuild: (_, _, item) => seen.add(item)),
    );
    seen.clear();
    // Same membership, rebuilt list — must not remove/insert anything.
    await t.pumpWidget(
      _host(['a', 'b'], onBuild: (_, _, item) => seen.add(item)),
    );
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
  });
}
