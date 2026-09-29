import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';
import 'package:watch_app/features/home/cubit/tracker_list_cubit.dart';
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

class _FakeContentModeCubit extends Cubit<ContentMode>
    implements ContentModeCubit {
  _FakeContentModeCubit(super.initial);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Connected (or not) tracker stub for the TV source chips + fetch path.
class _FakeTracker extends ChangeNotifier implements Tracker {
  _FakeTracker({
    required this.name,
    this.connected = false,
    this.list = const [],
    this.supportsReading = true,
  });

  final String name;
  final bool connected;
  final List<TrackerListItem> list;

  @override
  final bool supportsReading;

  @override
  String get displayName => name;

  @override
  bool get isConnected => connected;

  @override
  String? get viewerName => connected ? 'viewer' : null;

  @override
  String? get viewerAvatar => null;

  @override
  bool get autoSync => true;

  @override
  set autoSync(bool value) {}

  @override
  Future<bool> connect() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<TrackerListItem>> fetchList() async => list;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Lets tests emit an arbitrary [TrackerListState] without going through fetch.
class _SeededTrackerListCubit extends TrackerListCubit {
  void seed(TrackerListState state) => emit(state);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

MyListCubit _makeCubit(List<MediaItem> items) =>
    MyListCubit(_FakeMyListStore(items), _FakeListStatusStore());

Widget _pumpTree({
  required MyListCubit myList,
  required TrackerListCubit trackerList,
}) {
  return MultiBlocProvider(
    providers: [
      BlocProvider<MyListCubit>.value(value: myList),
      BlocProvider<TrackerListCubit>.value(value: trackerList),
    ],
    child: const MaterialApp(home: MyListScreenTv()),
  );
}

Future<void> _registerHub(List<Tracker> trackers) async {
  if (sl.isRegistered<TrackerHub>()) await sl.unregister<TrackerHub>();
  if (sl.isRegistered<ContentModeCubit>()) {
    await sl.unregister<ContentModeCubit>();
  }
  sl.registerSingleton<TrackerHub>(TrackerHub(trackers));
  sl.registerSingleton<ContentModeCubit>(
    _FakeContentModeCubit(ContentMode.anime),
  );
}

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
  const trackerItem = MediaItem(
    id: 'al-99',
    title: 'Jujutsu Kaisen',
    url: '',
    type: ProviderType.anime,
    sourceId: '',
  );

  setUp(() async {
    await sl.reset();
  });

  tearDown(() async {
    await sl.reset();
  });

  testWidgets(
    'MyListScreenTv renders poster cards and first card has autofocus',
    (tester) async {
      // No connected trackers → chip row hidden → first poster autofocuses.
      await _registerHub([_FakeTracker(name: 'AniList', connected: false)]);

      final cubit = _makeCubit([item1, item2]);
      final tlCubit = TrackerListCubit();
      addTearDown(cubit.close);
      addTearDown(tlCubit.close);

      await tester.pumpWidget(_pumpTree(myList: cubit, trackerList: tlCubit));
      await tester.pumpAndSettle();

      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Demon Slayer'), findsOneWidget);
      // No tracker chips when nothing is connected.
      expect(find.text('AniList'), findsNothing);

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(2));
      expect(focusables.first.autofocus, isTrue);
      expect(focusables.first.onLongPress, isNotNull);
    },
  );

  testWidgets(
    'MyListScreenTv shows empty state when cubit emits no entries',
    (tester) async {
      await _registerHub(const []);

      final cubit = _makeCubit([]);
      final tlCubit = TrackerListCubit();
      addTearDown(cubit.close);
      addTearDown(tlCubit.close);

      await tester.pumpWidget(_pumpTree(myList: cubit, trackerList: tlCubit));
      await tester.pumpAndSettle();

      expect(find.text('Titles you add appear here'), findsOneWidget);
      expect(find.byType(TvFocusable), findsNothing);
    },
  );

  testWidgets(
    'connected tracker shows a source chip; selecting it shows tracker titles',
    (tester) async {
      final anilist = _FakeTracker(
        name: 'AniList',
        connected: true,
        list: [
          const TrackerListItem(
            item: trackerItem,
            status: WatchStatus.watching,
          ),
        ],
      );
      await _registerHub([anilist]);

      final cubit = _makeCubit([item1]);
      final tlCubit = TrackerListCubit();
      addTearDown(cubit.close);
      addTearDown(tlCubit.close);

      await tester.pumpWidget(_pumpTree(myList: cubit, trackerList: tlCubit));
      await tester.pumpAndSettle();

      // Chips for My List + AniList; local title still showing.
      expect(find.text('My List'), findsWidgets);
      expect(find.text('AniList'), findsOneWidget);
      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Jujutsu Kaisen'), findsNothing);

      // First focusable is the My List chip (autofocus when chips exist).
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.first.autofocus, isTrue);

      await tester.tap(find.text('AniList'));
      await tester.pumpAndSettle();

      expect(find.text('Jujutsu Kaisen'), findsOneWidget);
      expect(find.text('Attack on Titan'), findsNothing);
    },
  );

  testWidgets(
    'tracker loading state shows a progress indicator',
    (tester) async {
      final anilist = _FakeTracker(name: 'AniList', connected: true);
      await _registerHub([anilist]);

      final cubit = _makeCubit([item1]);
      final tlCubit = _SeededTrackerListCubit()
        ..seed(TrackerListState(
          source: TrackerSource(anilist),
          status: TrackerListStatus.loading,
        ));
      addTearDown(cubit.close);
      addTearDown(tlCubit.close);

      await tester.pumpWidget(_pumpTree(myList: cubit, trackerList: tlCubit));
      // One frame only — pumpAndSettle never completes on an indeterminate
      // CircularProgressIndicator.
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets(
    'tracker empty and error states show dedicated copy',
    (tester) async {
      final anilist = _FakeTracker(name: 'AniList', connected: true);
      await _registerHub([anilist]);

      final cubit = _makeCubit([item1]);
      final tlCubit = _SeededTrackerListCubit()
        ..seed(TrackerListState(
          source: TrackerSource(anilist),
          status: TrackerListStatus.ready,
          entries: const [],
        ));
      addTearDown(cubit.close);
      addTearDown(tlCubit.close);

      await tester.pumpWidget(_pumpTree(myList: cubit, trackerList: tlCubit));
      await tester.pumpAndSettle();
      expect(find.text('No titles in this list'), findsOneWidget);

      tlCubit.seed(TrackerListState(
        source: TrackerSource(anilist),
        status: TrackerListStatus.error,
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('Couldn’t load — try again from Settings'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'MAL chip uses short label',
    (tester) async {
      await _registerHub([
        _FakeTracker(name: 'MyAnimeList', connected: true),
      ]);

      final cubit = _makeCubit([item1]);
      final tlCubit = TrackerListCubit();
      addTearDown(cubit.close);
      addTearDown(tlCubit.close);

      await tester.pumpWidget(_pumpTree(myList: cubit, trackerList: tlCubit));
      await tester.pumpAndSettle();

      expect(find.text('MAL'), findsOneWidget);
      expect(find.text('MyAnimeList'), findsNothing);
    },
  );
}
