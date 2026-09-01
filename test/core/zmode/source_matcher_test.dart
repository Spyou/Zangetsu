import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
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

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  final two = [(id: 'allanime', name: 'AllAnime'), (id: 'hianime', name: 'HiAnime')];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('matcher');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
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
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolveOn(fma, 'hianime', title: 'Fullmetal Alchemist: Brotherhood');
      expect(r?.sourceId, 'hianime');
      expect(repo.searched, ['hianime']); // allanime was never touched
      expect(store.get(fma, 'hianime')?.sourceId, 'hianime');
    });

    test('returns null (not a throw) when the named source genuinely lacks it', () async {
      final repo = _FakeSources({'allanime': [_hit('allanime', 'Naruto')]});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolveOn(fma, 'allanime', title: 'Fullmetal Alchemist: Brotherhood');
      expect(r, isNull);
      expect(store.get(fma, 'allanime'), isNull);
    });

    test('a throwing source returns null, not an exception', () async {
      final repo = _FakeSources({}, candidates: {'allanime'});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      expect(await m.resolveOn(fma, 'allanime', title: 'anything'), isNull);
    });
  });

  group('resolve', () {
    test('with no stored pick, the first candidate is the source', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
        'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
      });
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r?.sourceId, 'allanime');
      expect(store.get(fma, 'allanime')?.sourceId, 'allanime');
      // The defining rule: one source is asked, never a sweep of all of them.
      expect(repo.searched, ['allanime']);
    });

    test('honours a stored selection over candidate order', () async {
      await store.save(fma, const SourceMatch(sourceId: 'hianime',
          showUrl: 'u', showId: 'i', showTitle: 't', pinned: false));
      prefs.set(fma.kind, 'hianime');
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
      }, candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'anything');
      expect(r?.sourceId, 'hianime');
      expect(repo.searched, isEmpty); // selection short-circuited the sweep
    });

    test('a selected, installed source with no match returns null honestly, no fallback sweep', () async {
      prefs.set(fma.kind, 'allanime');
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Naruto')], // genuinely not FMA
        'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
      }, candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r, isNull);
      expect(repo.searched, ['allanime']); // hianime never tried
      expect(prefs.get(fma.kind), 'allanime'); // selection unchanged
    });

    test('a pick that was uninstalled falls back to one that still exists', () async {
      await store.save(fma, const SourceMatch(sourceId: 'allanime',
          showUrl: 'u', showId: 'i', showTitle: 't', pinned: false));
      await prefs.set(fma.kind, 'allanime');
      // allanime is gone — candidatesForKind only ever lists installed sources,
      // so the stored pick no longer appears in it.
      final repo = _FakeSources({'hianime': [_hit('hianime', 'FMA')]},
          installed: {'hianime'});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs,
          candidates: (_) => [(id: 'hianime', name: 'HiAnime')]);
      final r = await m.resolve(fma, title: 'FMA');
      expect(r?.sourceId, 'hianime');
      expect(store.get(fma, 'hianime')?.sourceId, 'hianime');
      // The stored pick is NOT rewritten by falling back — reinstall allanime
      // and it is the source again, without the user re-choosing it.
      expect(prefs.get(fma.kind), 'allanime');
    });

    test('a saved PINNED match on an uninstalled source is still honoured', () async {
      await store.pin(fma, const SourceMatch(sourceId: 'allanime',
          showUrl: 'u', showId: 'i', showTitle: 't', pinned: true));
      prefs.set(fma.kind, 'allanime');
      final repo = _FakeSources({'hianime': [_hit('hianime', 'FMA')]},
          installed: {'hianime'});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'FMA');
      expect(r?.sourceId, 'allanime');
      expect(repo.searched, isEmpty);
    });

    test('a dead selected source returns null, not an exception', () async {
      // allanime is the pick (first candidate) and throws. There is no longer
      // another source to fall through to, so this must be a clean null.
      final repo = _FakeSources({'hianime': [_hit('hianime', 'FMA')]},
          candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      expect(await m.resolve(fma, title: 'FMA'), isNull);
    });

    test('nothing anywhere returns null and saves/selects nothing', () async {
      final repo = _FakeSources({'allanime': [], 'hianime': []});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      expect(await m.resolve(fma, title: 'x'), isNull);
      expect(prefs.get(fma.kind), isNull);
    });

    test('a MAL id on the result beats a closer title', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Fullmetal Alchemist', malId: 121),
                     _hit('allanime', 'FMA Brotherhood', malId: 5114)],
      });
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => [two.first]);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist', malId: 5114);
      expect(r?.showUrl, 'https://allanime/FMA Brotherhood');
    });

    test('no source genuinely has the title returns null and saves nothing', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Naruto')],
        'hianime': [_hit('hianime', 'One Piece')],
      });
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r, isNull);
      expect(prefs.get(fma.kind), isNull);
    });

    test('a genuine match on the first source stops the search', () async {
      final repo = _FakeSources({
        'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
        'hianime': [_hit('hianime', 'Should not be reached')],
      });
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
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
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
      expect(r?.sourceId, 'allanime');
      expect(r?.showTitle, 'Hagane no Renkinjutsushi');
      expect(store.get(fma, 'allanime')?.sourceId, 'allanime');
    });

    test('the last candidate source throwing does not propagate', () async {
      // allanime is alive but has nothing; hianime (the last candidate) is dead.
      final repo = _FakeSources({'allanime': []}, candidates: {'allanime', 'hianime'});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      expect(await m.resolve(fma, title: 'anything'), isNull);
      expect(prefs.get(fma.kind), isNull);
    });
  });

  group('saved', () {
    test('answers for the selected source only', () async {
      await store.save(fma, const SourceMatch(sourceId: 'allanime',
          showUrl: 'a', showId: 'a', showTitle: 'a', pinned: false));
      await store.save(fma, const SourceMatch(sourceId: 'hianime',
          showUrl: 'h', showId: 'h', showTitle: 'h', pinned: false));
      final m = SourceMatcher(sources: _FakeSources({}), store: store, prefs: prefs, candidates: (_) => two);
      // No stored pick — the first candidate is the source, so its match answers.
      expect(m.saved(fma)?.sourceId, 'allanime');
      await prefs.set(fma.kind, 'hianime');
      expect(m.saved(fma)?.sourceId, 'hianime');
    });
  });

  group('pinManual', () {
    test('pins the pick and selects its source', () async {
      final repo = _FakeSources({});
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      final r = await m.pinManual(fma, _hit('hianime', 'FMA'));
      expect(r.pinned, isTrue);
      expect(store.get(fma, 'hianime')?.pinned, isTrue);
      expect(prefs.get(fma.kind), 'hianime');
    });
  });



  group('remembered misses', () {
    // Every candidate answers, none of them with this title.
    _FakeSources noneHaveIt() => _FakeSources({
      'allanime': [_hit('allanime', 'Something Else')],
      'hianime': [_hit('hianime', 'Another Thing')],
    });

    test('a source that said no is not asked again on the next resolve', () async {
      final repo = noneHaveIt();
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);

      expect(await m.resolve(fma, title: 'Fullmetal Alchemist'), isNull);
      expect(repo.searched, ['allanime']);

      // Opening the title again used to pay for the same search, every visit.
      repo.searched.clear();
      expect(await m.resolve(fma, title: 'Fullmetal Alchemist'), isNull);
      expect(repo.searched, isEmpty);
    });

    test('the miss expires, so a source that later adds the title is found',
        () async {
      final repo = noneHaveIt();
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
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
      final m = SourceMatcher(sources: repo, store: store, prefs: prefs, candidates: (_) => two);
      await m.resolve(fma, title: 'Fullmetal Alchemist');
      expect(store.missedRecently(fma, 'allanime'), isTrue);

      await m.pinManual(fma, _hit('allanime', 'Fullmetal Alchemist'));
      expect(store.missedRecently(fma, 'allanime'), isFalse);
    });
  });
}
