import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/cubit/wrong_title_cubit.dart';

class _Src implements SourceRepository {
  _Src({this.fail = false});
  final bool fail;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'allanime', name: 'AllAnime'),
    (id: 'hianime', name: 'HiAnime'),
  ];
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async {
    if (fail) throw StateError('dead');
    return [MediaItem(id: 'fmab', title: 'FMA: Brotherhood',
        url: 'https://$sourceId/fmab', type: ProviderType.anime, sourceId: sourceId!)];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');

  WrongTitleCubit build(_Src src) => WrongTitleCubit(
    sources: src,
    matcher: SourceMatcher(sources: src, store: store, candidates: (_) => src.loadedSources),
    canonical: fma,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongshow_cubit');
    Hive.init(dir.path);
    store = await MatchStore.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('starts on the first source with no results', () {
    final c = build(_Src());
    expect(c.state.sourceId, 'allanime');
    expect(c.state.results, isEmpty);
    expect(c.state.loading, isFalse);
  });

  test('search fills results and clears loading', () async {
    final c = build(_Src());
    await c.search('fma');
    expect(c.state.results.single.id, 'fmab');
    expect(c.state.loading, isFalse);
  });

  test('picking a source re-searches against it', () async {
    final c = build(_Src());
    c.pickSource('hianime');
    await c.search('fma');
    expect(c.state.sourceId, 'hianime');
    expect(c.state.results.single.sourceId, 'hianime');
  });

  test('a dead source empties results instead of throwing', () async {
    final c = build(_Src(fail: true));
    await c.search('fma');
    expect(c.state.results, isEmpty);
    expect(c.state.loading, isFalse);
  });

  test('choose pins the pick', () async {
    final c = build(_Src());
    await c.search('fma');
    final m = await c.choose(c.state.results.single);
    expect(m.pinned, isTrue);
    expect(store.get(fma)?.showId, 'fmab');
  });
}
