// The library row used to be a horizontal ListView of tap targets over a
// single grid rebuilt by setState. It is a TabBar/TabBarView now so the pages
// can be swiped, which puts a TabController in the picture — and a
// TabController's length is fixed at construction while this row's is not. A
// status emptying out or a category being made changes how many tabs there
// are, and a TabBarView whose child count disagrees with its controller
// throws. That is what these cover.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';
import 'package:watch_app/features/home/library_tabs.dart';

LibraryTab _tab(String id) => LibraryTab(
  id: id,
  label: id,
  count: 0,
  test: (_) => true,
);

/// Pumps the row with a changeable tab list, recording what it reports.
class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.initial,
    required this.selected,
  });

  final List<String> initial;
  final String selected;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<String> ids = widget.initial;
  late String selected = widget.selected;
  final reported = <String>[];

  void setTabs(List<String> next) => setState(() => ids = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: LibraryTabs(
        tabs: [for (final id in ids) _tab(id)],
        selectedId: selected,
        onSelected: (id) => setState(() {
          reported.add(id);
          selected = id;
        }),
        bodyFor: (t) => Center(child: Text('body:${t.id}')),
      ),
    ),
  );
}

void main() {
  testWidgets('swiping the page moves the selection', (tester) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      _Harness(key: key, initial: const ['all', 'watching'], selected: 'all'),
    );
    expect(find.text('body:all'), findsOneWidget);

    await tester.fling(find.text('body:all'), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    expect(key.currentState!.reported, ['watching']);
    expect(find.text('body:watching'), findsOneWidget);
  });

  testWidgets('a tab disappearing rebuilds the controller', (tester) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      _Harness(
        key: key,
        initial: const ['all', 'watching', 'completed'],
        selected: 'all',
      ),
    );

    // Completed empties out, so its tab goes with it.
    key.currentState!.setTabs(const ['all', 'watching']);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('completed'), findsNothing);
    expect(find.text('body:all'), findsOneWidget);
  });

  testWidgets('a tab added from outside is moved to', (tester) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      _Harness(key: key, initial: const ['all'], selected: 'all'),
    );

    // Making a category should land on it, the way the + button does.
    key.currentState!
      ..selected = 'cat:1'
      ..setTabs(const ['all', 'cat:1']);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('body:cat:1'), findsOneWidget);
  });

  testWidgets('the add button is not a tab you can swipe onto', (
    tester,
  ) async {
    var added = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryTabs(
            tabs: [_tab('all')],
            selectedId: 'all',
            onSelected: (_) {},
            onAdd: () => added++,
            bodyFor: (t) => Center(child: Text('body:${t.id}')),
          ),
        ),
      ),
    );

    expect(find.byType(Tab), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();

    expect(added, 1);
  });

  test('a tab keeps its own filter, so pages can sit side by side', () {
    final watching = LibraryTab(
      id: 'status:watching',
      label: 'Watching',
      count: 1,
      test: (e) => e.status == WatchStatus.watching,
    );
    const item = MediaItem(
      id: 'a',
      title: 'A',
      url: 'u',
      type: ProviderType.anime,
      sourceId: 's',
    );

    expect(watching.test(const MyListEntry(item, WatchStatus.watching)), isTrue);
    expect(watching.test(const MyListEntry(item, WatchStatus.dropped)), isFalse);
  });
}
