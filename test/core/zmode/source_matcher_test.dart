import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

MediaItem _hit(String src, String title, {int? malId, String? englishTitle}) => MediaItem(
  id: title.toLowerCase(), title: title, url: 'https://$src/$title', type: ProviderType.anime,
  sourceId: src, malId: malId, englishTitle: englishTitle);

/// search() per source id. Sources not listed throw, like a dead source.
/// [installed] backs [hasSource] — defaults to every id [bySource] AND
/// [candidates] mention, so a test has to opt IN to an uninstalled source
/// rather than accidentally getting one from a bare `bySource` map.
class _FakeSources implements SourceRepository {
  _FakeSources(this.bySource, {Set<String>? installed, Set<String>? candidates})
      : installed = installed ?? {...bySource.keys, ...?candidates};
  final Map<String, List<MediaItem>> bySource;
  final Set<String> installed;
  final searched = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => installed.contains(sourceId);

  @override
  Future<List<MediaItem>> search(String query, {String category = 'sub', String? sourceId}) async {
    searched.add(sourceId!);
    final r = bySource[sourceId];
    if (r == null) throw StateError('dead');
    return r;
  }
}

/// Records how many searches are in flight AT ONCE, and lets a source be made
/// slow, so the sweep's concurrency and its ordering can be asserted without
/// depending on wall-clock timing.
class _ConcurrentSources implements SourceRepository {
  _ConcurrentSources(this.bySource, {this.slow = const {}});
  final Map<String, List<MediaItem>> bySource;

  /// Sources that yield to the event loop [slow] times before answering, so a
  /// later-but-faster source would win any race decided by reply order.
  final Map<String, int> slow;

  final searched = <String>[];
  int _live = 0;
  int peak = 0;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);

  @override
  Future<List<MediaItem>> search(String query,
      {String category = 'sub', String? sourceId}) async {
    searched.add(sourceId!);
    _live++;
    if (_live > peak) peak = _live;
    for (var i = 0; i < (slow[sourceId] ?? 0); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    _live--;
    return bySource[sourceId] ?? const [];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  final two = [(id: 'allanime', name: 'AllAnime'), (id: 'hianime', name: 'HiAnime')];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('matcher');
    Hive.init(dir.path);
    store = await MatchStore.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('resolveOn', () {
    test('matches on exactly the named source', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Naruto')],
        'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
      }, candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolveOn(fma, 'hianime', title: 'Fullmetal Alchemist: Brotherhood');
      expect(r?.sourceId, 'hianime');
      expect(repo.searched, ['hianime']); // allanime was never touched
      expect(store.get(fma, 'hianime')?.sourceId, 'hianime');
    });

    test('returns null (not a throw) when the named source genuinely lacks it', () async {
      final repo = _FakeSources({'allanime': [_hit('allanime', 'Naruto')]});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolveOn(fma, 'allanime', title: 'Fullmetal Alchemist: Brotherhood');
      expect(r, isNull);
      expect(store.get(fma, 'allanime'), isNull);
    });

    test('a throwing source returns null, not an exception', () async {
      final repo = _FakeSources({}, candidates: {'allanime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      expect(await m.resolveOn(fma, 'allanime', title: 'anything'), isNull);
    });
  });

  group('resolve', () {
    test('finds the title on the first source that has it, saves it and selects it', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Naruto')],
        'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
      });
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r?.sourceId, 'hianime');
      expect(store.get(fma, 'hianime')?.sourceId, 'hianime');
      expect(store.selectedSource(fma), 'hianime');
    });

    test('honours a stored selection over candidate order', () async {
      await store.save(fma, const SourceMatch(sourceId: 'hianime',
          showUrl: 'u', showId: 'i', showTitle: 't', pinned: false));
      await store.selectSource(fma, 'hianime');
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
      }, candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'anything');
      expect(r?.sourceId, 'hianime');
      expect(repo.searched, isEmpty); // selection short-circuited the sweep
    });

    test('a selected, installed source with no match returns null honestly, no fallback sweep', () async {
      await store.selectSource(fma, 'allanime');
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Naruto')], // genuinely not FMA
        'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
      }, candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r, isNull);
      expect(repo.searched, ['allanime']); // hianime never tried
      expect(store.selectedSource(fma), 'allanime'); // selection unchanged
    });

    test('a saved unpinned match on an uninstalled source searches again', () async {
      await store.save(fma, const SourceMatch(sourceId: 'allanime',
          showUrl: 'u', showId: 'i', showTitle: 't', pinned: false));
      await store.selectSource(fma, 'allanime');
      // allanime was uninstalled since the match was saved; only hianime is left.
      final repo = _FakeSources({'hianime': [_hit('hianime', 'FMA')]},
          installed: {'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'FMA');
      expect(r?.sourceId, 'hianime');
      expect(store.get(fma, 'hianime')?.sourceId, 'hianime');
      expect(store.selectedSource(fma), 'hianime');
    });

    test('a saved PINNED match on an uninstalled source is still honoured', () async {
      await store.pin(fma, const SourceMatch(sourceId: 'allanime',
          showUrl: 'u', showId: 'i', showTitle: 't', pinned: true));
      await store.selectSource(fma, 'allanime');
      final repo = _FakeSources({'hianime': [_hit('hianime', 'FMA')]},
          installed: {'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'FMA');
      expect(r?.sourceId, 'allanime');
      expect(repo.searched, isEmpty);
    });

    test('a pin on a non-selected candidate still wins when the sweep reaches it', () async {
      // Pinned earlier, then the user moved the selection elsewhere and that
      // source later vanished — the sweep falls back to hianime, which still
      // carries its own pin and must not be re-searched over.
      await store.pin(fma, const SourceMatch(sourceId: 'hianime',
          showUrl: 'https://h/pinned', showId: 'pinned', showTitle: 'FMA', pinned: true));
      await store.selectSource(fma, 'allanime'); // then uninstalled + unpinned
      final repo = _FakeSources({'hianime': [_hit('hianime', 'wrong result')]},
          installed: {'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'anything');
      expect(r?.showId, 'pinned');
      expect(repo.searched, isEmpty); // never re-searched hianime
      expect(store.selectedSource(fma), 'hianime');
    });

    test('a dead source is skipped, not fatal', () async {
      final repo = _FakeSources({'hianime': [_hit('hianime', 'FMA')]},
          candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'FMA');
      expect(r?.sourceId, 'hianime');
    });

    test('nothing anywhere returns null and saves/selects nothing', () async {
      final repo = _FakeSources({'allanime': [], 'hianime': []});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      expect(await m.resolve(fma, title: 'x'), isNull);
      expect(store.selectedSource(fma), isNull);
    });

    test('a MAL id on the result beats a closer title', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Fullmetal Alchemist', malId: 121),
                     _hit('allanime', 'FMA Brotherhood', malId: 5114)],
      });
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => [two.first]);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist', malId: 5114);
      expect(r?.showUrl, 'https://allanime/FMA Brotherhood');
    });

    test('no source genuinely has the title returns null and saves nothing', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Naruto')],
        'hianime': [_hit('hianime', 'One Piece')],
      });
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r, isNull);
      expect(store.selectedSource(fma), isNull);
    });

    test('a genuine match on the first source stops the search', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
        'hianime': [_hit('hianime', 'Should not be reached')],
      });
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r?.sourceId, 'allanime');
      expect(repo.searched, ['allanime']);
    });

    test('a romaji title with a matching englishTitle is accepted', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Hagane no Renkinjutsushi',
            englishTitle: 'Fullmetal Alchemist: Brotherhood')],
        'hianime': [_hit('hianime', 'Should not be reached')],
      });
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r?.sourceId, 'allanime');
      expect(r?.showTitle, 'Hagane no Renkinjutsushi');
      expect(store.get(fma, 'allanime')?.sourceId, 'allanime');
    });

    test('the last candidate source throwing does not propagate', () async {
      // allanime is alive but has nothing; hianime (the last candidate) is dead.
      final repo = _FakeSources({'allanime': []}, candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      expect(await m.resolve(fma, title: 'anything'), isNull);
      expect(store.selectedSource(fma), isNull);
    });
  });

  group('saved', () {
    test('answers for the selected source only', () async {
      await store.save(fma, const SourceMatch(sourceId: 'allanime',
          showUrl: 'a', showId: 'a', showTitle: 'a', pinned: false));
      await store.save(fma, const SourceMatch(sourceId: 'hianime',
          showUrl: 'h', showId: 'h', showTitle: 'h', pinned: false));
      final m = SourceMatcher(sources: _FakeSources({}), store: store, candidates: (_) => two);
      expect(m.saved(fma), isNull); // nothing selected yet
      await store.selectSource(fma, 'hianime');
      expect(m.saved(fma)?.sourceId, 'hianime');
    });
  });

  group('pinManual', () {
    test('pins the pick and selects its source', () async {
      final repo = _FakeSources({});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      final r = await m.pinManual(fma, _hit('hianime', 'FMA'));
      expect(r.pinned, isTrue);
      expect(store.get(fma, 'hianime')?.pinned, isTrue);
      expect(store.selectedSource(fma), 'hianime');
    });
  });

  group('parallel sweep', () {
    // 5 candidates; only the last has it, so the whole list gets searched.
    List<({String id, String name})> five() => const [
      (id: 's0', name: 'S0'),
      (id: 's1', name: 'S1'),
      (id: 's2', name: 'S2'),
      (id: 's3', name: 'S3'),
      (id: 's4', name: 'S4'),
    ];

    test('the first candidate is probed alone, the rest go out together',
        () async {
      final repo = _ConcurrentSources({
        's0': [_hit('s0', 'Nope')],
        's1': [_hit('s1', 'Nope')],
        's2': [_hit('s2', 'Nope')],
        's3': [_hit('s3', 'Nope')],
        's4': [_hit('s4', 'FMA')],
        // every one is made slow so overlap is observable at all
      }, slow: {'s0': 2, 's1': 2, 's2': 2, 's3': 2, 's4': 2});
      final m = SourceMatcher(
          sources: repo, store: store, candidates: (_) => five());

      expect((await m.resolve(fma, title: 'FMA'))?.sourceId, 's4');
      expect(repo.searched.length, 5);
      // s0 alone, then s1..s4 four-wide.
      expect(repo.peak, 4);
    });

    test('a slow earlier source still beats a fast later one', () async {
      final repo = _ConcurrentSources({
        's0': [_hit('s0', 'Nope')], // head misses, so the tail runs in parallel
        's1': [_hit('s1', 'FMA')], // slow, but earlier
        's2': [_hit('s2', 'FMA')], // instant, but later
      }, slow: {'s1': 8});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => const [
        (id: 's0', name: 'S0'),
        (id: 's1', name: 'S1'),
        (id: 's2', name: 'S2'),
      ]);

      // Candidate order decides, not who replied first — otherwise which
      // source a title lands on would change between runs.
      expect((await m.resolve(fma, title: 'FMA'))?.sourceId, 's1');
      expect(store.selectedSource(fma), 's1');
    });
  });

  group('concurrent resolves', () {
    test('two at once for the same title sweep only once', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'FMA')],
        'hianime': [_hit('hianime', 'FMA')],
      });
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);

      // What the Detail screen does: the episode list and the source-selector
      // row both ask for the same title at the same moment.
      final both = await Future.wait([
        m.resolve(fma, title: 'FMA'),
        m.resolve(fma, title: 'FMA'),
      ]);

      expect(both[0]?.sourceId, 'allanime');
      expect(both[1]?.sourceId, 'allanime');
      expect(repo.searched, ['allanime'], reason: 'one sweep, not two');
    });

    test('a later resolve still sweeps once the first has finished', () async {
      final repo = _FakeSources({'allanime': [], 'hianime': [_hit('hianime', 'FMA')]});
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      await m.resolve(fma, title: 'FMA');
      expect(repo.searched, ['allanime', 'hianime']);
      // The in-flight entry must be cleared on completion, not leaked — a
      // second, later call is a fresh question, answered from the store here.
      repo.searched.clear();
      expect((await m.resolve(fma, title: 'FMA'))?.sourceId, 'hianime');
      expect(repo.searched, isEmpty);
    });
  });

  group('remembered misses', () {
    // Every candidate answers, none of them with this title.
    _FakeSources noneHaveIt() => _FakeSources({
      'allanime': [_hit('allanime', 'Something Else')],
      'hianime': [_hit('hianime', 'Another Thing')],
    });

    test('a title nothing has re-asks no one on the next resolve', () async {
      final repo = noneHaveIt();
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);

      expect(await m.resolve(fma, title: 'Fullmetal Alchemist'), isNull);
      expect(repo.searched, ['allanime', 'hianime']);

      // This is the whole point: opening the title again used to pay for the
      // same two searches, every visit, forever.
      repo.searched.clear();
      expect(await m.resolve(fma, title: 'Fullmetal Alchemist'), isNull);
      expect(repo.searched, isEmpty);
    });

    test('the miss expires, so a source that later adds the title is found',
        () async {
      final repo = noneHaveIt();
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      await m.resolve(fma, title: 'Fullmetal Alchemist');
      expect(store.missedRecently(fma, 'allanime'), isTrue);

      // Age the record past the TTL by writing an older timestamp.
      await store.rememberMiss(fma, 'allanime');
      expect(store.missedRecently(fma, 'allanime'), isTrue);
      await store.forgetMiss(fma, 'allanime');
      expect(store.missedRecently(fma, 'allanime'), isFalse);

      repo.searched.clear();
      await m.resolve(fma, title: 'Fullmetal Alchemist');
      expect(repo.searched, ['allanime'],
          reason: 'the forgotten source is asked again; hianime still is not');
    });

    test('a manual pin clears that source\'s miss', () async {
      final repo = noneHaveIt();
      final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
      await m.resolve(fma, title: 'Fullmetal Alchemist');
      expect(store.missedRecently(fma, 'hianime'), isTrue);

      await m.pinManual(fma, _hit('hianime', 'Fullmetal Alchemist'));
      expect(store.missedRecently(fma, 'hianime'), isFalse);
    });
  });
}
