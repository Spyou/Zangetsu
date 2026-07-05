import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/see_all_screen.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  // Null cover keeps PosterCard on its placeholder — no network in tests.
  cover: null,
  url: 'https://x.test/$id',
  type: ProviderType.anime,
  sourceId: 'ani:1',
);

List<MediaItem> _page(int start, int count) => [
  for (var i = start; i < start + count; i++) _item('m$i'),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  setUp(() {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
  });

  testWidgets('onLoadMore == null keeps a fixed list (no pagination)', (
    tester,
  ) async {
    var loadCalls = 0;
    await tester.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Fixed',
          items: _page(0, 30),
          onTap: (_) {},
          onLoadMore: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No loading spinner is ever attached in the non-paginating configuration.
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Dragging to the bottom must NOT fetch anything.
    await tester.fling(find.byType(GridView), const Offset(0, -4000), 4000);
    await tester.pumpAndSettle();
    expect(loadCalls, 0);
  });

  testWidgets('appends the next page and dedupes already-seen items', (
    tester,
  ) async {
    final pagesRequested = <int>[];
    await tester.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Paged',
          items: _page(0, 30), // page 1: m0..m29
          onTap: (_) {},
          onLoadMore: (page) async {
            pagesRequested.add(page);
            if (page == 2) {
              // Overlaps page 1 by one item (m29) to exercise dedupe.
              return [_item('m29'), ..._page(30, 20)]; // m30..m49 + dup
            }
            return const []; // page 3 → end of list
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Scroll to the bottom to trip the near-end threshold.
    await tester.fling(find.byType(GridView), const Offset(0, -6000), 6000);
    await tester.pumpAndSettle();

    // Page 2 was requested and its NEW items appended (dup m29 dropped):
    // 30 (page 1) + 20 unique (m30..m49, the leading m29 deduped) = 50.
    expect(pagesRequested.contains(2), isTrue);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate = grid.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 50);
  });

  testWidgets('stops paging once a page returns nothing new', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'EndSoon',
          items: _page(0, 30),
          onTap: (_) {},
          onLoadMore: (page) async {
            calls++;
            return const []; // immediately end
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Fling to bottom a few times; the empty first response sets _end, so no
    // matter how often we reach the bottom afterwards it never fetches again.
    for (var i = 0; i < 3; i++) {
      await tester.fling(find.byType(GridView), const Offset(0, -6000), 6000);
      await tester.pumpAndSettle();
    }
    expect(calls, 1);
  });
}
