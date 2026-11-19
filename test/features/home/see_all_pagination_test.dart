import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
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

  testWidgets('lazyFixedList reveals a fixed list in batches on scroll', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Lazy JS',
          items: _page(0, 50),
          onTap: (_) {},
          lazyFixedList: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    GridView grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.childrenDelegate as SliverChildBuilderDelegate).childCount,
      24,
    );

    await tester.fling(find.byType(GridView), const Offset(0, -6000), 6000);
    await tester.pumpAndSettle();
    grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.childrenDelegate as SliverChildBuilderDelegate).childCount,
      greaterThan(24),
    );

    await tester.fling(find.byType(GridView), const Offset(0, -6000), 6000);
    await tester.pumpAndSettle();
    grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.childrenDelegate as SliverChildBuilderDelegate).childCount,
      50,
    );
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

  testWidgets('service catalogue search and filter controls are available', (
    tester,
  ) async {
    final queries = <String>[];
    await tester.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Netflix',
          items: _page(0, 2),
          onTap: (_) {},
          filterKind: ZKind.movie,
          onSearch: (query, filters, page) async {
            queries.add(query);
            return MediaItemPage(items: _page(20, 1), hasMore: false);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('see-all-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('see-all-filter')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('see-all-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('see-all-search-field')),
      'Dune',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(queries, ['Dune']);

    await tester.tap(find.byKey(const ValueKey('see-all-filter')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('GENRES'), findsOneWidget);
    expect(find.text('YEAR'), findsOneWidget);
    expect(find.text('FORMAT'), findsOneWidget);
    expect(find.text('STATUS'), findsNothing);
  });

  testWidgets('an empty service search page can continue to later pages', (
    tester,
  ) async {
    final pagesRequested = <int>[];
    await tester.pumpWidget(
      _wrap(
        SeeAllScreen(
          title: 'Netflix',
          items: _page(0, 2),
          onTap: (_) {},
          filterKind: ZKind.movie,
          onSearch: (query, filters, page) async {
            pagesRequested.add(page);
            return page == 1
                ? const MediaItemPage(items: [], hasMore: true)
                : MediaItemPage(items: _page(20, 1), hasMore: false);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('see-all-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('see-all-search-field')),
      'Dune',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(pagesRequested, [1]);
    expect(find.byKey(const ValueKey('see-all-next-page')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('see-all-next-page')));
    await tester.pumpAndSettle();
    expect(pagesRequested, [1, 2]);
    expect(find.text('m20'), findsOneWidget);
  });
}
