import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';

/// Counts what actually reached a tracker, so a gate that silently swallows a
/// write is distinguishable from one that lets it through.
class _CountingTracker extends ChangeNotifier implements Tracker {
  int watching = 0;
  int scrobbles = 0;

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
  Future<List<TrackerListItem>> fetchList() async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;

  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

void main() {
  late Directory tempDir;
  late _CountingTracker tracker;
  late TrackerHub hub;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('auto_track_test');
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
  });

  test('auto-track defaults on, so a fresh install syncs as it always did', () {
    expect(sl<PlaybackPrefs>().autoTrack, isTrue);
  });

  test('auto-track on: playback writes reach the tracker', () async {
    await hub.markWatching(malId: 1, title: 'Show');
    await hub.scrobble(malId: 1, title: 'Show', episode: 3);
    expect(tracker.watching, 1);
    expect(tracker.scrobbles, 1);
  });

  test('auto-track off: nothing is written just from watching', () async {
    await sl<PlaybackPrefs>().setAutoTrack(false);
    await hub.markWatching(malId: 1, title: 'Show');
    await hub.scrobble(malId: 1, title: 'Show', episode: 3);
    expect(tracker.watching, 0);
    expect(tracker.scrobbles, 0);
  });

  test(
    'auto-track off: a by-hand mark still goes out (auto: false)',
    () async {
      await sl<PlaybackPrefs>().setAutoTrack(false);
      await hub.scrobble(malId: 1, title: 'Show', episode: 3, auto: false);
      expect(tracker.scrobbles, 1);
    },
  );
}
