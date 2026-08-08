import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';

/// Records the [MediaKind] it was called with, for every kind-aware method.
class _FakeTracker extends ChangeNotifier implements Tracker {
  @override
  bool get supportsReading => true;

  MediaKind? scrobbleKind;

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
  }) async {
    scrobbleKind = kind;
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrackerHub kind forwarding', () {
    test('explicit kind: MediaKind.manga reaches every registered tracker',
        () async {
      final a = _FakeTracker();
      final b = _FakeTracker();
      final hub = TrackerHub([a, b]);

      await hub.scrobble(malId: 1, episode: 5, kind: MediaKind.manga);

      expect(a.scrobbleKind, MediaKind.manga);
      expect(b.scrobbleKind, MediaKind.manga);
    });

    test('omitting kind forwards MediaKind.anime (the compile-time default)',
        () async {
      final a = _FakeTracker();
      final hub = TrackerHub([a]);

      await hub.scrobble(malId: 1, episode: 5); // kind not passed

      expect(a.scrobbleKind, MediaKind.anime);
    });
  });

  group('SimklService manga no-op', () {
    test('scrobble(kind: MediaKind.manga) no-ops without touching Simkl',
        () async {
      // A Dio that fails any request — proves the manga gate returns before
      // ever reaching the network (Simkl has no manga/novel API).
      final dio = Dio()
        ..httpClientAdapter = _ThrowingAdapter();
      final simkl = SimklService(dio);
      addTearDown(simkl.dispose);

      await expectLater(
        simkl.scrobble(malId: 1, episode: 5, kind: MediaKind.manga),
        completes,
      );
    });
  });
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw StateError('no network call expected for manga kind on Simkl');
  }
}
