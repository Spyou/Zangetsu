import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/ui/tracker_sync_sheet.dart';

/// A connected fake tracker that records the [MediaKind] it was queried/
/// written with and hands back a canned [TrackerEntry] — no network.
class _FakeTracker extends ChangeNotifier implements Tracker {
  @override
  bool get supportsReading => true;

  _FakeTracker(this.name, {this.entry});

  final String name;
  TrackerEntry? entry;
  MediaKind? lastFetchKind;
  MediaKind? lastUpdateKind;

  @override
  String get displayName => name;
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
    MediaKind kind = MediaKind.anime,
  }) async {}

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
  }) async {
    lastFetchKind = kind;
    return entry;
  }

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
  }) async {
    lastUpdateKind = kind;
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(() async {
    await sl.reset();
  });

  Widget harness(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('anime item (reading: false, the default) shows EPISODES '
      'WATCHED, not CHAPTERS READ', (tester) async {
    final al = _FakeTracker(
      'AniList',
      entry: const TrackerEntry(
        trackerName: 'AniList',
        onList: true,
        progress: 10,
        maxEpisodes: 24,
      ),
    );
    sl.registerSingleton<TrackerHub>(TrackerHub([al]));

    await tester.pumpWidget(
      harness(const TrackerSyncSheet(title: 'Some Anime', isAnime: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('EPISODES WATCHED'), findsOneWidget);
    expect(find.text('CHAPTERS READ'), findsNothing);
    expect(find.text('10 / 24'), findsOneWidget);
    expect(al.lastFetchKind, MediaKind.anime);
  });

  testWidgets('reading item (reading: true) shows CHAPTERS READ, not '
      'EPISODES WATCHED', (tester) async {
    final al = _FakeTracker(
      'AniList',
      entry: const TrackerEntry(
        trackerName: 'AniList',
        onList: true,
        progress: 5,
        chapters: 12,
      ),
    );
    sl.registerSingleton<TrackerHub>(TrackerHub([al]));

    await tester.pumpWidget(
      harness(
        const TrackerSyncSheet(
          title: 'Some Manga',
          isAnime: false,
          reading: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CHAPTERS READ'), findsOneWidget);
    expect(find.text('EPISODES WATCHED'), findsNothing);
    expect(find.text('5 / 12'), findsOneWidget);
    expect(al.lastFetchKind, MediaKind.manga);
  });

  testWidgets('a connected Simkl shows it cannot track manga when reading', (
    tester,
  ) async {
    final al = _FakeTracker('AniList');
    final simkl = _FakeTracker('Simkl');
    sl.registerSingleton<TrackerHub>(TrackerHub([al, simkl]));

    await tester.pumpWidget(
      harness(
        const TrackerSyncSheet(
          title: 'Some Manga',
          isAnime: false,
          reading: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('no manga'), findsOneWidget);
  });

  testWidgets(
    "Simkl's no-manga note does NOT show for an anime item (unchanged)",
    (tester) async {
      final al = _FakeTracker('AniList');
      final simkl = _FakeTracker('Simkl');
      sl.registerSingleton<TrackerHub>(TrackerHub([al, simkl]));

      await tester.pumpWidget(
        harness(const TrackerSyncSheet(title: 'Some Anime', isAnime: true)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('no manga'), findsNothing);
    },
  );
}
