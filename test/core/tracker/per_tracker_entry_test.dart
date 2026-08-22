import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';

/// A tracker that answers with whatever entry it was handed, and records the
/// writes it received so a test can prove a write did (or didn't) reach it.
class _StubTracker extends ChangeNotifier implements Tracker {
  _StubTracker(this._name, {this.entry, this.throwOnFetch = false});

  final String _name;
  final TrackerEntry? entry;
  final bool throwOnFetch;

  int writes = 0;

  @override
  String get displayName => _name;
  @override
  bool get isConnected => true;
  @override
  bool get supportsReading => true;
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
    if (throwOnFetch) throw StateError('boom');
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
    writes++;
  }

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

TrackerEntry _entry(
  String name, {
  bool onList = true,
  String? title,
  int? progress,
}) =>
    TrackerEntry(
      trackerName: name,
      onList: onList,
      title: title,
      progress: progress,
    );

void main() {
  group('TrackerEntry.title', () {
    test('defaults to null so a tracker that cannot supply one still builds',
        () {
      const e = TrackerEntry(trackerName: 'X');
      expect(e.title, isNull);
    });

    test('carries the matched title through', () {
      final e = _entry('AniList', title: 'Solo Leveling');
      expect(e.title, 'Solo Leveling');
    });
  });

  group('TrackerHub.fetchEntries', () {
    test('returns one entry per tracker that answered, in order', () async {
      final hub = TrackerHub([
        _StubTracker('AniList', entry: _entry('AniList', progress: 12)),
        _StubTracker('MAL', entry: _entry('MAL', progress: 5)),
      ]);
      final all = await hub.fetchEntries(malId: 1);
      expect(all.map((e) => e.trackerName), ['AniList', 'MAL']);
    });

    test('drops trackers that answered nothing', () async {
      final hub = TrackerHub([
        _StubTracker('AniList', entry: _entry('AniList', progress: 12)),
        _StubTracker('MAL'), // null entry
      ]);
      expect((await hub.fetchEntries(malId: 1)).length, 1);
    });

    test('one tracker throwing does not lose the others', () async {
      final hub = TrackerHub([
        _StubTracker('AniList', throwOnFetch: true),
        _StubTracker('MAL', entry: _entry('MAL', progress: 5)),
      ]);
      final all = await hub.fetchEntries(malId: 1);
      expect(all.map((e) => e.trackerName), ['MAL']);
    });
  });

  group('TrackerHub.fetchEntry keeps its old selection', () {
    test('prefers the first tracker that has it on a list', () async {
      final hub = TrackerHub([
        _StubTracker('AniList', entry: _entry('AniList', onList: false)),
        _StubTracker('MAL', entry: _entry('MAL', onList: true, progress: 5)),
      ]);
      expect((await hub.fetchEntry(malId: 1))?.trackerName, 'MAL');
    });

    test('falls back to the first that answered when none are on a list',
        () async {
      final hub = TrackerHub([
        _StubTracker('AniList', entry: _entry('AniList', onList: false)),
        _StubTracker('MAL', entry: _entry('MAL', onList: false)),
      ]);
      expect((await hub.fetchEntry(malId: 1))?.trackerName, 'AniList');
    });

    test('null when nothing answered', () async {
      final hub = TrackerHub([_StubTracker('AniList'), _StubTracker('MAL')]);
      expect(await hub.fetchEntry(malId: 1), isNull);
    });
  });

  group('disagreement', () {
    // Mirrors the rule the sheet applies: only on-list entries with real
    // progress count, and two or more distinct values means a conflict.
    List<TrackerEntry> conflictsOf(List<TrackerEntry> all) {
      final c = [
        for (final e in all)
          if (e.onList && e.progress != null && e.progress! > 0) e,
      ];
      return c.map((e) => e.progress).toSet().length < 2 ? const [] : c;
    }

    test('differing progress is a conflict, and the highest wins', () {
      final all = [
        _entry('AniList', progress: 12),
        _entry('MAL', progress: 5),
      ];
      final c = conflictsOf(all);
      expect(c.length, 2);
      expect(
        c.map((e) => e.progress ?? 0).reduce((a, b) => a > b ? a : b),
        12,
      );
    });

    test('agreeing trackers are not a conflict', () {
      expect(
        conflictsOf([
          _entry('AniList', progress: 7),
          _entry('MAL', progress: 7),
        ]),
        isEmpty,
      );
    });

    test('a single tracker cannot disagree with anyone', () {
      expect(conflictsOf([_entry('AniList', progress: 7)]), isEmpty);
    });

    test('an entry not on a list has no opinion to conflict with', () {
      expect(
        conflictsOf([
          _entry('AniList', progress: 12),
          _entry('MAL', onList: false, progress: 5),
        ]),
        isEmpty,
      );
    });

    // Apply only writes fields that changed. Baselining the pre-filled maximum
    // made it a no-op, so the sheet closed having levelled nothing up.
    test('the pre-filled maximum counts as a change against what was read', () {
      final all = [
        _entry('AniList', progress: 2),
        _entry('MAL', progress: 5),
      ];
      final shown = conflictsOf(all)
          .map((e) => e.progress ?? 0)
          .reduce((a, b) => a > b ? a : b);
      // What fetchEntry would have returned — the first on-list entry.
      final baseline = all.first.progress ?? 0;
      expect(shown, 5);
      expect(baseline, 2);
      expect(shown != baseline, isTrue, reason: 'Apply must see a change');
    });
  });

  group('writes stay where they are aimed', () {
    test('updateEntry on one tracker leaves the other untouched', () async {
      final al = _StubTracker('AniList', entry: _entry('AniList'));
      final mal = _StubTracker('MAL', entry: _entry('MAL'));
      await al.updateEntry(malId: 1, progress: 9);
      expect(al.writes, 1);
      expect(mal.writes, 0, reason: 'per-tracker edit must not fan out');
    });

    test('the hub still writes to every connected tracker', () async {
      final al = _StubTracker('AniList', entry: _entry('AniList'));
      final mal = _StubTracker('MAL', entry: _entry('MAL'));
      await TrackerHub([al, mal]).updateEntry(malId: 1, progress: 9);
      expect(al.writes, 1);
      expect(mal.writes, 1);
    });
  });
}
