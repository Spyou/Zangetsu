import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';
import 'package:watch_app/features/home/my_list_screen_tv.dart';

// ── Minimal fakes ─────────────────────────────────────────────────────────────

/// Stub [MyListStore]: returns a fixed list of [MediaItem]s with no Hive or
/// Appwrite dependency. Only [all] and [revision] are called by [MyListCubit].
class _FakeMyListStore implements MyListStore {
  _FakeMyListStore(this._items) : revision = ValueNotifier<int>(0);

  final List<MediaItem> _items;

  @override
  final ValueNotifier<int> revision;

  @override
  List<MediaItem> all() => List<MediaItem>.from(_items);

  @override
  bool contains(MediaItem m) => _items.any((i) => i.id == m.id);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Stub [ListStatusStore]: returns null status for every item (no Hive needed).
/// Only [statusOf] and [revision] are called by [MyListCubit].
class _FakeListStatusStore implements ListStatusStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  @override
  WatchStatus? statusOf(MediaItem m) => null;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

MyListCubit _makeCubit(List<MediaItem> items) =>
    MyListCubit(_FakeMyListStore(items), _FakeListStatusStore());

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  const item1 = MediaItem(
    id: '1',
    title: 'Attack on Titan',
    url: '/aot',
    type: ProviderType.anime,
    sourceId: 'test',
  );
  const item2 = MediaItem(
    id: '2',
    title: 'Demon Slayer',
    url: '/ds',
    type: ProviderType.anime,
    sourceId: 'test',
  );

  testWidgets(
    'MyListScreenTv renders poster cards and first card has autofocus',
    (tester) async {
      final cubit = _makeCubit([item1, item2]);
      addTearDown(cubit.close);

      await tester.pumpWidget(
        BlocProvider<MyListCubit>.value(
          value: cubit,
          child: const MaterialApp(home: MyListScreenTv()),
        ),
      );
      await tester.pumpAndSettle();

      // Both titles are rendered as poster cards.
      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Demon Slayer'), findsOneWidget);

      // At least 2 TvFocusable cards are present.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(2));

      // The very first TvFocusable (first poster card) has autofocus=true.
      expect(focusables.first.autofocus, isTrue);
    },
  );

  testWidgets(
    'MyListScreenTv shows empty state when cubit emits no entries',
    (tester) async {
      final cubit = _makeCubit([]);
      addTearDown(cubit.close);

      await tester.pumpWidget(
        BlocProvider<MyListCubit>.value(
          value: cubit,
          child: const MaterialApp(home: MyListScreenTv()),
        ),
      );
      await tester.pumpAndSettle();

      // No poster cards — empty state message visible.
      expect(find.text('Titles you add appear here'), findsOneWidget);
      expect(find.byType(TvFocusable), findsNothing);
    },
  );
}
