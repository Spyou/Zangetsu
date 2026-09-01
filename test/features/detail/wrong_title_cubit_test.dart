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
import 'package:watch_app/features/detail/cubit/wrong_title_cubit.dart';

class _Src implements SourceRepository {
  _Src({this.fail = false});
  final bool fail;
  final searched = <String>[];
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  String baseUrlFor(String id) =>
      id.startsWith('ani:') || id.startsWith('mihon:') || id.startsWith('lnr:')
          ? 'https://example.test'
          : '';
  @override
  bool hasSource(String sourceId) => true;
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async {
    searched.add(sourceId!);
    if (fail) throw StateError('dead');
    return [MediaItem(id: 'fmab', title: 'FMA: Brotherhood',
        url: 'https://$sourceId/fmab', type: ProviderType.anime, sourceId: sourceId)];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');

  WrongTitleCubit build(_Src src, {String sourceId = 'allanime'}) => WrongTitleCubit(
    sources: src,
    matcher: SourceMatcher(sources: src, store: store, prefs: prefs,
        candidates: (_) => [(id: 'allanime', name: 'AllAnime'), (id: 'hianime', name: 'HiAnime')]),
    canonical: fma,
    sourceId: sourceId,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongshow_cubit');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('starts with no results, scoped to the given source', () {
    final c = build(_Src());
    expect(c.sourceId, 'allanime');
    expect(c.state.results, isEmpty);
    expect(c.state.loading, isFalse);
  });

  test('search only ever searches the fixed source', () async {
    final src = _Src();
    final c = build(src, sourceId: 'hianime');
    await c.search('fma');
    expect(src.searched, ['hianime']);
    expect(c.state.results.single.sourceId, 'hianime');
    expect(c.state.loading, isFalse);
  });

  test('a dead source empties results instead of throwing', () async {
    final c = build(_Src(fail: true));
    await c.search('fma');
    expect(c.state.results, isEmpty);
    expect(c.state.loading, isFalse);
  });

  test('choose pins the pick for its source', () async {
    final c = build(_Src(), sourceId: 'hianime');
    await c.search('fma');
    final m = await c.choose(c.state.results.single);
    expect(m.pinned, isTrue);
    expect(store.get(fma, 'hianime')?.showId, 'fmab');
    expect(prefs.get(fma.kind), 'hianime');
  });
}
