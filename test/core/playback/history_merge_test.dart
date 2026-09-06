// One show watched two ways used to be two rows in Continue Watching: history
// is keyed sourceId::showUrl, so opening a title from Home ('zm' + a zm:// url)
// and from a source's own browse screen (that source's id and url) recorded it
// twice, at two different episodes, and only the catalogue one scrobbled.
//
// New watches stopped splitting when the browse screen started resolving to the
// catalogue. This covers the rows already on disk. The dangerous part is that
// the merge DELETES the old row, so it may only act on an identity it is sure
// of — a MAL id — and must never guess.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/history_merge.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

import 'watch_history_supabase_test.dart' show FakeHistoryRemote;

HistoryEntry _sourceRow({
  String sourceId = 'animecube',
  String showUrl = 'https://cube/renegade',
  int? malId = 5114,
  double? episodeNumber = 3,
  String episodeId = 'ep-3',
  int updatedAt = 2000,
  Duration position = const Duration(minutes: 7),
}) => HistoryEntry(
  sourceId: sourceId,
  showId: showUrl,
  showTitle: 'Renegade Immortal',
  cover: 'https://cube/cover.jpg',
  showUrl: showUrl,
  category: 'sub',
  episodeId: episodeId,
  episodeNumber: episodeNumber,
  episodeUrl: '$showUrl/$episodeId',
  position: position,
  duration: const Duration(minutes: 24),
  updatedAt: updatedAt,
  malId: malId,
);

void main() {
  late Directory dir;
  late WatchHistory history;
  late ResumeStore resume;
  late MatchStore matches;
  late FakeHistoryRemote remote;

  const canonicalUrl = 'zm://anime/mal:5114';
  const canonical = ZCanonical(ZKind.anime, 'mal:5114');

  Future<int> run() => HistoryCanonicalMerge.runOnce(
    history: history,
    resume: resume,
    matches: matches,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_merge');
    Hive.init(dir.path);
    await WatchHistory.init();
    await ResumeStore.init();
    remote = FakeHistoryRemote();
    history = WatchHistory(SupabaseService(), () => 'user1', remote: remote);
    resume = ResumeStore();
    matches = await MatchStore.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a source row becomes the catalogue row', () async {
    await history.save(_sourceRow());

    expect(await run(), 1);

    final rows = history.all();
    expect(rows.length, 1);
    expect(rows.single.sourceId, ZmodeIds.sourceId);
    expect(rows.single.showId, canonicalUrl);
    expect(rows.single.showUrl, canonicalUrl);
    expect(rows.single.episodeId, '3');
    expect(rows.single.episodeUrl, '$canonicalUrl/ep/3');
    expect(rows.single.position, const Duration(minutes: 7));
  });

  test('the source it was watched on is kept for that title', () async {
    // Without this the merged row would play on the kind's default source,
    // quietly moving the show to somewhere it was never watched.
    await history.save(_sourceRow());
    await run();

    final pin = matches.pinnedFor(canonical);
    expect(pin?.sourceId, 'animecube');
    expect(pin?.showUrl, 'https://cube/renegade');
  });

  test('the resume position moves with it', () async {
    // History carries a position, but the player reads ResumeStore, keyed the
    // same way — miss it and the merged row resumes from zero.
    await history.save(_sourceRow());
    await resume.save(
      'animecube',
      'https://cube/renegade',
      'ep-3',
      const Duration(minutes: 7),
      const Duration(minutes: 24),
    );

    await run();

    final mark = resume.get(ZmodeIds.sourceId, canonicalUrl, '3');
    expect(mark?.position, const Duration(minutes: 7));
    expect(mark?.duration, const Duration(minutes: 24));
  });

  test('the old row is dropped from the cloud too', () async {
    await history.save(_sourceRow());
    expect(remote.rows.any((r) => r['source_id'] == 'animecube'), isTrue);

    await run();

    expect(remote.rows.any((r) => r['source_id'] == 'animecube'), isFalse);
    expect(remote.rows.any((r) => r['source_id'] == ZmodeIds.sourceId), isTrue);
  });

  group('what it refuses to touch', () {
    test('a row with no MAL id is left alone', () async {
      // No exact identity, and guessing would move progress onto another show
      // and then delete the original.
      await history.save(_sourceRow(malId: null));

      expect(await run(), 0);
      expect(history.all().single.sourceId, 'animecube');
    });

    test('a half episode number is left alone', () async {
      await history.save(_sourceRow(episodeNumber: 12.5));
      expect(await run(), 0);
      expect(history.all().single.sourceId, 'animecube');
    });

    test('rows that are already canonical are left alone', () async {
      await history.save(HistoryEntry(
        sourceId: ZmodeIds.sourceId,
        showId: canonicalUrl,
        showTitle: 'Xian Ni',
        showUrl: canonicalUrl,
        category: 'sub',
        episodeId: '1',
        episodeNumber: 1,
        episodeUrl: '$canonicalUrl/ep/1',
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 24),
        updatedAt: 1000,
        malId: 5114,
      ));

      expect(await run(), 0);
      expect(history.all().single.episodeId, '1');
    });
  });

  test('a newer catalogue row wins; the stale source row is just dropped',
      () async {
    await history.save(HistoryEntry(
      sourceId: ZmodeIds.sourceId,
      showId: canonicalUrl,
      showTitle: 'Xian Ni',
      showUrl: canonicalUrl,
      category: 'sub',
      episodeId: '9',
      episodeNumber: 9,
      episodeUrl: '$canonicalUrl/ep/9',
      position: const Duration(minutes: 3),
      duration: const Duration(minutes: 24),
      updatedAt: 5000,
      malId: 5114,
    ));
    await history.save(_sourceRow(updatedAt: 2000));

    expect(await run(), 1);

    final rows = history.all();
    expect(rows.length, 1);
    // Episode 9, not the older source row's 3.
    expect(rows.single.episodeId, '9');
  });

  test('an older catalogue row is overwritten by the newer source row',
      () async {
    await history.save(HistoryEntry(
      sourceId: ZmodeIds.sourceId,
      showId: canonicalUrl,
      showTitle: 'Xian Ni',
      showUrl: canonicalUrl,
      category: 'sub',
      episodeId: '1',
      episodeNumber: 1,
      episodeUrl: '$canonicalUrl/ep/1',
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 24),
      updatedAt: 1000,
      malId: 5114,
    ));
    await history.save(_sourceRow(updatedAt: 9000));

    await run();

    final rows = history.all();
    expect(rows.length, 1);
    expect(rows.single.episodeId, '3');
  });

  test('it runs once, not on every launch', () async {
    await history.save(_sourceRow());
    expect(await run(), 1);
    await history.save(_sourceRow(showUrl: 'https://cube/another'));
    expect(await run(), 0);
  });

  test('two shows both move', () async {
    await history.save(_sourceRow());
    await history.save(_sourceRow(
      sourceId: 'hianime',
      showUrl: 'https://h/other',
      malId: 21,
      episodeNumber: 5,
    ));

    expect(await run(), 2);
    expect(history.all().every((r) => r.sourceId == ZmodeIds.sourceId), isTrue);
  });
}
