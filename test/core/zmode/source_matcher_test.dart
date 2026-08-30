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
}
