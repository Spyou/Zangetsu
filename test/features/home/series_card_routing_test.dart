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
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/my_list_screen.dart';
import 'package:watch_app/features/home/series_screen.dart';

class _Store implements MyListStore {
  _Store(this._items) : revision = ValueNotifier<int>(0);
  final List<MediaItem> _items;
  @override
  final ValueNotifier<int> revision;
  @override
  List<MediaItem> all() => _items;
  @override
  bool contains(MediaItem m) => _items.any((i) => i.id == m.id);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Statuses implements ListStatusStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  @override
  WatchStatus? statusOf(MediaItem m) => null;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Series implements SeriesGroupStore {
  _Series({this.memberKeys = const ['s::g1']});
  final List<String> memberKeys;
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  @override
  List<SeriesGroup> all() => [
    SeriesGroup(
      id: 'g1',
      title: 'Merged Show',
      position: 0,
      memberKeys: memberKeys,
    ),
  ];
  @override
  SeriesGroup? groupOf(String key) =>
      memberKeys.contains(key) ? all().single : null;
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

Future<void> _pumpMyList(WidgetTester t) async {
  await sl.reset();
  addTearDown(() => sl.reset());
  sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  sl.registerSingleton<TrackerHub>(TrackerHub(const []));
  sl.registerSingleton<ListStatusStore>(_Statuses());
  sl.registerSingleton<SeriesGroupStore>(_Series());
  sl.registerSingleton<ContentModeCubit>(_Mode(ContentMode.anime));
  sl.registerSingleton<MyListStore>(
    _Store([
      const MediaItem(
        id: 'g1',
        title: 'Season 1',
        url: 's::g1',
        type: ProviderType.anime,
        sourceId: 's',
      ),
    ]),
  );
  t.view.physicalSize = const Size(800, 1200);
  t.view.devicePixelRatio = 1.0;
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
}

void main() {
  testWidgets('tapping a grouped card opens SeriesScreen', (t) async {
    await _pumpMyList(t);

    expect(find.text('Merged Show'), findsWidgets);
    await t.tap(find.text('Merged Show').first);
    await t.pumpAndSettle();

    expect(find.byType(SeriesScreen), findsOneWidget);
  });
}
