import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_binding_store.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/ui/tracker_list_sheet.dart';

/// A connected tracker that hands back a canned entry and records what a
/// removal was actually aimed at — the thing that matters when the user has
/// corrected a wrong match by hand.
class _FakeTracker extends ChangeNotifier implements Tracker {
  _FakeTracker({this.entry});

  final TrackerEntry? entry;

  int removeCalls = 0;
  String? removedPinnedId;

  @override
  String get displayName => 'AniList';
  @override
  bool get supportsReading => true;
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
  }) async {}

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {
    removeCalls++;
    removedPinnedId = pinnedId;
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
  }) async => entry;

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

/// The real store writes to Hive, and a real disk future never resolves inside
/// the widget test's fake-async zone — the confirm dialog would deadlock
/// against the sheet's loading spinner. Same public behaviour, in memory.
class _MemoryBindingStore extends TrackerBindingStore {
  final Map<String, Map<String, String>> _data = {};

  @override
  Map<String, String> get(String key) => _data[key] ?? const {};

  @override
  Future<void> set(String key, String trackerName, String id) async =>
      _data.putIfAbsent(key, () => {})[trackerName] = id;

  @override
  Future<void> remove(String key, String trackerName) async {
    final m = _data[key];
    if (m == null) return;
    m.remove(trackerName);
    if (m.isEmpty) _data.remove(key);
  }

  @override
  Future<void> clear(String key) async => _data.remove(key);
}

void main() {
  const bindingKey = 'src|show';

  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<TrackerBindingStore>(_MemoryBindingStore());
  });

  tearDown(() => sl.reset());

  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackerListSheet(
            title: 'Solo Leveling',
            isAnime: true,
            malId: 1,
            bindingKey: bindingKey,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Remove aims at the pinned match, not the guessed one', (
    tester,
  ) async {
    final fake = _FakeTracker(
      entry: const TrackerEntry(
        trackerName: 'AniList',
        onList: true,
        title: 'Solo Leveling',
        url: 'https://anilist.co/anime/999',
      ),
    );
    sl.registerSingleton<TrackerHub>(TrackerHub([fake]));
    // The user corrected the match by hand — 999 is the entry that must go.
    await sl<TrackerBindingStore>().set(bindingKey, 'AniList', '999');

    await pumpSheet(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove tracking'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(fake.removeCalls, 1);
    expect(fake.removedPinnedId, '999', reason: 'must delete the pinned entry');
    expect(
      sl<TrackerBindingStore>().get(bindingKey),
      isEmpty,
      reason: 'a pin to a deleted entry would re-bind the next read',
    );
  });

  testWidgets('nothing on a list means nothing to remove', (tester) async {
    sl.registerSingleton<TrackerHub>(
      TrackerHub([
        _FakeTracker(
          entry: const TrackerEntry(trackerName: 'AniList', onList: false),
        ),
      ]),
    );
    await pumpSheet(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Remove tracking'), findsNothing);
    expect(find.text('Open in browser'), findsOneWidget);
  });

  testWidgets('an unmatched row cannot open or copy a link', (tester) async {
    sl.registerSingleton<TrackerHub>(TrackerHub([_FakeTracker()]));
    await pumpSheet(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    final open = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Open in browser'),
    );
    final copy = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Copy link'),
    );
    expect(open.enabled, isFalse);
    expect(copy.enabled, isFalse);
  });
}
