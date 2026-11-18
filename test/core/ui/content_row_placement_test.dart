import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/ui/content_row.dart';

/// The row equivalent of the library grid's glide test: removing a card must
/// slide its neighbours from their old slot instead of teleporting them.
void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    await sl.reset();
  });

  testWidgets('row removal glides neighbours instead of snapping', (t) async {
    Widget host(List<String> items) => MaterialApp(
      home: Scaffold(
        body: ContentRow(
          title: 'Row',
          itemWidth: 190,
          itemHeight: 107,
          itemCount: items.length,
          itemKeys: items,
          itemBuilder: (context, index) =>
              Text(items[index], key: ValueKey(items[index])),
        ),
      ),
    );

    await t.pumpWidget(host(['a', 'b', 'c', 'd']));
    await t.pumpAndSettle();
    await t.pumpWidget(host(['a', 'c', 'd']));
    // Mid-glide: moved cards carry a live leftward translate.
    await t.pump(const Duration(milliseconds: 100));
    final offsets = t
        .widgetList<Transform>(find.byType(Transform))
        .map((w) => w.transform.getTranslation())
        .where((o) => o.x != 0 || o.y != 0);
    expect(offsets, isNotEmpty);
    expect(
      offsets.every((o) => o.x > 0 && o.y == 0),
      isTrue,
      reason: 'row moves are purely horizontal, old slot to the right',
    );
    // ... and no entrance replays: every card stays fully opaque.
    for (final o in t.widgetList<Opacity>(find.byType(Opacity))) {
      expect(o.opacity, 1.0);
    }
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('b'), findsNothing);
    for (final label in ['a', 'c', 'd']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(t.takeException(), isNull);
  });
}
