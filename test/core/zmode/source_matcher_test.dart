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
class _FakeSources implements SourceRepository {
  _FakeSources(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  final searched = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

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

  test('finds the title on the first source that has it and saves it', () async {
    final repo = _FakeSources({
      'allanime': [_hit('allanime', 'Naruto')],
      'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
    });
    final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
    final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
    expect(r?.sourceId, 'hianime');
    expect(store.get(fma)?.sourceId, 'hianime');
  });

  test('a saved match short-circuits the search', () async {
    await store.save(fma, const SourceMatch(sourceId: 'allanime',
        showUrl: 'u', showId: 'i', showTitle: 't', pinned: false));
    final repo = _FakeSources({});
    final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
    final r = await m.resolve(fma, title: 'anything');
    expect(r?.sourceId, 'allanime');
    expect(repo.searched, isEmpty);
  });

  test('a dead source is skipped, not fatal', () async {
    final repo = _FakeSources({'hianime': [_hit('hianime', 'FMA')]});
    final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
    final r = await m.resolve(fma, title: 'FMA');
    expect(r?.sourceId, 'hianime');
  });

  test('nothing anywhere returns null and saves nothing', () async {
    final repo = _FakeSources({'allanime': [], 'hianime': []});
    final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
    expect(await m.resolve(fma, title: 'x'), isNull);
    expect(store.get(fma), isNull);
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

  test('pinManual stores the pick as pinned', () async {
    final repo = _FakeSources({});
    final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
    final r = await m.pinManual(fma, _hit('hianime', 'FMA'));
    expect(r.pinned, isTrue);
    expect(store.get(fma)?.pinned, isTrue);
  });

  test('no source genuinely has the title returns null and saves nothing', () async {
    final repo = _FakeSources({
      'allanime': [_hit('allanime', 'Naruto')],
      'hianime': [_hit('hianime', 'One Piece')],
    });
    final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
    final r = await m.resolve(fma, title: 'Fullmetal Alchemist: Brotherhood');
    expect(r, isNull);
    expect(store.get(fma), isNull);
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
    expect(store.get(fma)?.sourceId, 'allanime');
  });

  test('the last candidate source throwing does not propagate', () async {
    // allanime is alive but has nothing; hianime (the last candidate) is dead.
    final repo = _FakeSources({'allanime': []});
    final m = SourceMatcher(sources: repo, store: store, candidates: (_) => two);
    expect(await m.resolve(fma, title: 'anything'), isNull);
    expect(store.get(fma), isNull);
  });
}
