import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/series_groups.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/my_list_screen.dart';

/// End-to-end remove flow on the own list: long-press → Remove → ash →
/// commit → slot glides shut. No poster flash, no empty slot, no blink — the
/// entry is gone and the survivor holds its (new) place.
class _Store implements MyListStore {
  _Store(this._items) : revision = ValueNotifier<int>(0);
  final List<MediaItem> _items;

  @override
  final ValueNotifier<int> revision;

  @override
  List<MediaItem> all() => List<MediaItem>.from(_items);

  @override
  bool contains(MediaItem m) => _items.any((i) => i.id == m.id);

  @override
  Future<void> remove(MediaItem m) async {
    _items.removeWhere((i) => i.id == m.id);
    revision.value++;
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Statuses implements ListStatusStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  @override
  WatchStatus? statusOf(MediaItem m) => WatchStatus.watching;

  @override
  Future<void> remove(MediaItem m) async {}

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Mode extends Cubit<ContentMode> implements ContentModeCubit {
  _Mode(super.initial);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Auth extends Cubit<AuthState> implements AuthCubit {
  _Auth(super.initial);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const _alpha = MediaItem(
  id: 'a',
  title: 'Alpha Show',
  url: '/a',
  type: ProviderType.anime,
  sourceId: 's',
);

const _beta = MediaItem(
  id: 'b',
  title: 'Beta Show',
  url: '/b',
  type: ProviderType.anime,
  sourceId: 's',
);

class _FakeSeriesGroupStore implements SeriesGroupStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  @override
  List<SeriesGroup> all() => const [];
  @override
  SeriesGroup? groupOf(String key) => null;
  @override
  Future<void> purgeTitle(String key) async {}
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<TrackerHub>(TrackerHub(const []));
    sl.registerSingleton<ListStatusStore>(_Statuses());
    sl.registerSingleton<SeriesGroupStore>(_FakeSeriesGroupStore());
    sl.registerSingleton<ContentModeCubit>(_Mode(ContentMode.anime));
  });

  tearDown(() async {
    await sl.reset();
  });

  testWidgets('remove dissolves the card and closes the slot without residue', (
    t,
  ) async {
    sl.registerSingleton<MyListStore>(_Store([_alpha, _beta]));
    t.view.physicalSize = const Size(800, 1200);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: BlocProvider<AuthCubit>.value(
          value: _Auth(
            const AuthState(
              status: AuthStatus.authenticated,
              user: AuthUser(id: 'u1', name: 'T', email: 't@example.com'),
            ),
          ),
          child: const MyListScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(PosterCard), findsNWidgets(2));

    await t.longPress(find.text('Alpha Show'));
    await t.pumpAndSettle();
    // The test viewport is short, so the sheet scrolls — drag its content
    // up like a finger would (on a real phone it all fits).
    await t.drag(find.byType(BottomSheet), const Offset(0, -400));
    await t.pumpAndSettle();
    expect(find.text('Remove from list'), findsOneWidget);
    await t.tap(find.widgetWithText(ListTile, 'Remove from list'));

    // Ash plays; the snapshot race resolves on rendered frames (no wall-time
    // dependence), the commit runs, the reload drops the entry and the grid
    // glides shut.
    await t.pump();
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pumpAndSettle();

    expect(find.text('Alpha Show'), findsNothing);
    expect(find.text('Beta Show'), findsOneWidget);
    expect(find.byType(PosterCard), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
