// Task 12 fix round 1, Finding 1: ListStatusSheet is the one long-form
// `.label` consumer, so it's the one place labelFor() needed wiring.
//
// Final whole-branch review, Findings 1+4: `reading` now comes from the
// ITEM's type (not the global ContentModeCubit) — the one source of truth
// also drives the tracker `kind:` passed to hub.setStatus/removeFromList in
// _syncToTrackers. These tests cover both: the label follows `item.type`,
// and a manga/anime item forwards the matching MediaKind to the tracker hub.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/ui/list_status_sheet.dart';

/// Minimal in-memory [MyListStore] stand-in — no Hive box needed.
class _FakeMyListStore implements MyListStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  bool _inList = false;

  @override
  bool contains(MediaItem m) => _inList;

  @override
  Future<void> add(MediaItem m) async => _inList = true;

  @override
  Future<void> remove(MediaItem m) async => _inList = false;

  @override
  Future<void> pushStatus(MediaItem m) async {}

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

/// Minimal in-memory [ListStatusStore] stand-in — no Hive box needed.
class _FakeListStatusStore implements ListStatusStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  WatchStatus? _status;

  @override
  WatchStatus? statusOf(MediaItem m) => _status;

  @override
  Future<void> setStatus(MediaItem m, WatchStatus status) async =>
      _status = status;

  @override
  Future<void> remove(MediaItem m) async => _status = null;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

/// Records the [MediaKind] of every setStatus/removeFromList call. Mirrors
/// media_kind_test.dart's `_FakeTracker`.
class _FakeTracker extends ChangeNotifier implements Tracker {
  @override
  bool get supportsReading => true;

  MediaKind? lastSetStatusKind;
  MediaKind? lastRemoveKind;

  @override
  String get displayName => 'Fake';
  @override
  bool get isConnected => true;
  @override
  String? get viewerName => 'someone';
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
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {}

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {
    lastSetStatusKind = kind;
  }

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    lastRemoveKind = kind;
  }

  @override
  Future<List<TrackerListItem>> fetchList() async => const [];

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async => null;

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;
  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

const _animeItem = MediaItem(
  id: 'a1',
  title: 'Anime Item',
  url: 'http://test/a1',
  type: ProviderType.anime,
  sourceId: 'test',
  malId: 1,
);

const _mangaItem = MediaItem(
  id: 'm1',
  title: 'Manga Item',
  url: 'http://test/m1',
  type: ProviderType.manga,
  sourceId: 'test',
  malId: 2,
);

void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<ListStatusStore>(_FakeListStatusStore());
  });

  tearDown(() async {
    await sl.reset();
  });

  Future<void> pumpSheet(WidgetTester tester, MediaItem item) async {
    // The default 800x600 test viewport is too short for the real
    // showModalBottomSheet flow (unlike pumping ListStatusSheet directly
    // into a Scaffold body, which had the full height) — widen it so the
    // sheet's five rows don't overflow.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showListStatusSheet(context, item: item),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'anime item keeps the unchanged long labels (Watching / Plan to Watch)',
    (tester) async {
      await pumpSheet(tester, _animeItem);

      expect(find.text('Watching'), findsOneWidget);
      expect(find.text('Plan to Watch'), findsOneWidget);
      expect(find.text('Reading'), findsNothing);
      expect(find.text('Plan to Read'), findsNothing);
    },
  );

  testWidgets(
    'a manga item shows Reading / Plan to Read instead',
    (tester) async {
      await pumpSheet(tester, _mangaItem);

      expect(find.text('Reading'), findsOneWidget);
      expect(find.text('Plan to Read'), findsOneWidget);
      expect(find.text('Watching'), findsNothing);
      expect(find.text('Plan to Watch'), findsNothing);
    },
  );

  testWidgets(
    'Completed/Paused/Dropped are unchanged for a manga item',
    (tester) async {
      await pumpSheet(tester, _mangaItem);

      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Dropped'), findsOneWidget);
    },
  );

  // ── Findings 1+4: tracker kind forwarding ─────────────────────────────

  testWidgets(
    'setting a status on a manga item forwards kind: manga to the tracker '
    'hub, not the default anime',
    (tester) async {
      final fake = _FakeTracker();
      sl.registerSingleton<TrackerHub>(TrackerHub([fake]));

      await pumpSheet(tester, _mangaItem);
      await tester.tap(find.text('Reading'));
      await tester.pumpAndSettle();

      expect(fake.lastSetStatusKind, MediaKind.manga);
    },
  );

  testWidgets(
    'setting a status on an anime item forwards kind: anime',
    (tester) async {
      final fake = _FakeTracker();
      sl.registerSingleton<TrackerHub>(TrackerHub([fake]));

      await pumpSheet(tester, _animeItem);
      await tester.tap(find.text('Watching'));
      await tester.pumpAndSettle();

      expect(fake.lastSetStatusKind, MediaKind.anime);
    },
  );

  testWidgets(
    'removing a manga item from the list forwards kind: manga to '
    'removeFromList — the exact write this fix stops from landing on the '
    'wrong (anime) list',
    (tester) async {
      final fake = _FakeTracker();
      sl.registerSingleton<TrackerHub>(TrackerHub([fake]));

      // First add it, so "Remove from list" is offered.
      await pumpSheet(tester, _mangaItem);
      await tester.tap(find.text('Reading'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from list'));
      await tester.pumpAndSettle();

      expect(fake.lastRemoveKind, MediaKind.manga);
    },
  );

  testWidgets(
    'does not overflow on a 720p landscape TV with every row present',
    (tester) async {
      sl.registerSingleton<AppMode>(const AppMode(isTv: true));
      await sl<MyListStore>().add(_animeItem);

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () =>
                    showListStatusSheet(context, item: _animeItem),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Add to your list'), findsOneWidget);
      expect(find.text('Remove from list'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
