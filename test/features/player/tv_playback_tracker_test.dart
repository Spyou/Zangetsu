import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/tv_playback_tracker.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';

class _CountingTracker extends ChangeNotifier implements Tracker {
  int watching = 0;
  int scrobbles = 0;
  final List<int> scrobbledEpisodes = [];

  @override
  bool get supportsReading => true;
  @override
  String get displayName => 'Counting';
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
  }) async {
    watching++;
  }

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
  }) async {
    scrobbles++;
    scrobbledEpisodes.add(episode);
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
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {}

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
  }) async =>
      null;

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
  }) async =>
      const [];

  @override
  Future<List<TrackerListItem>> fetchList() async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;

  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

Episode _ep(int number) =>
    Episode(id: 'e$number', title: 'Episode $number', url: '/$number', number: number.toDouble());

void main() {
  late Directory tempDir;
  late _CountingTracker tracker;
  late TrackerHub hub;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tv_playback_tracker_test');
    Hive.init(tempDir.path);
    await PlaybackPrefs.init();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  });

  tearDownAll(() async {
    await sl.reset();
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    tracker = _CountingTracker();
    hub = TrackerHub([tracker]);
    await sl<PlaybackPrefs>().setAutoTrack(true);
    IncognitoMode.set(false);
  });

  TvPlaybackTracker makeTracker() => TvPlaybackTracker(
        malId: 42,
        scrobbleTitle: 'Show',
        hub: hub,
      );

  group('TvPlaybackTracker', () {
    test('scrobbles at/after 92%', () {
      final t = makeTracker();
      t.maybeMarkWatching();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 9200,
        durationMs: 10000,
      );
      expect(tracker.watching, 1);
      expect(tracker.scrobbles, 1);
      expect(tracker.scrobbledEpisodes, [1]);
    });

    test('does not scrobble below 92% without force', () {
      final t = makeTracker();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 5000,
        durationMs: 10000,
      );
      expect(tracker.scrobbles, 0);
    });

    test('force-scrobbles on completion below 92%', () {
      final t = makeTracker();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 5000,
        durationMs: 10000,
        force: true,
      );
      expect(tracker.scrobbles, 1);
    });

    test('does not double-scrobble the same index', () {
      final t = makeTracker();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 9500,
        durationMs: 10000,
      );
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 9900,
        durationMs: 10000,
        force: true,
      );
      expect(tracker.scrobbles, 1);
    });

    test('skips non-integer episode numbers', () {
      final t = makeTracker();
      t.maybeScrobble(
        index: 0,
        episode: Episode(id: 'sp', title: 'Special', url: '/sp', number: 12.5),
        positionMs: 9500,
        durationMs: 10000,
        force: true,
      );
      expect(tracker.scrobbles, 0);
    });

    test('no-op without a title id', () {
      final t = TvPlaybackTracker(hub: hub);
      t.maybeMarkWatching();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 9500,
        durationMs: 10000,
        force: true,
      );
      expect(tracker.watching, 0);
      expect(tracker.scrobbles, 0);
    });

    test('respects auto-track off', () async {
      await sl<PlaybackPrefs>().setAutoTrack(false);
      final t = makeTracker();
      t.maybeMarkWatching();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 9500,
        durationMs: 10000,
        force: true,
      );
      expect(tracker.watching, 0);
      expect(tracker.scrobbles, 0);
    });

    test('reset clears scrobbled state', () {
      final t = makeTracker();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 9500,
        durationMs: 10000,
      );
      t.reset();
      t.maybeScrobble(
        index: 0,
        episode: _ep(1),
        positionMs: 9500,
        durationMs: 10000,
      );
      expect(tracker.scrobbles, 2);
    });
  });
}
