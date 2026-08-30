// Hard constraint (task 15 brief): switching a title's playback source must
// never move a user's watch progress. In Z Mode, video watch history is keyed
// `zm::<canonical>` and resume `zm::<canonical>::<episodeId>` — the pseudo
// source id (ZmodeIds.sourceId) plus the canonical id plus the metadata
// episode id, none of which come from SourceMatch/MatchStore. Concretely, the
// player is always launched with `sourceId: item.sourceId` and
// `showUrl: item.url` (see DetailScreen._openPlayer), which for a Z Mode item
// are 'zm' and the zm:// show url — properties of the metadata item itself,
// never the matched source's showId/showUrl. This test proves that identity
// (and therefore the ResumeStore/WatchHistory key built from it) is a pure
// function of the canonical, unaffected by anything MatchStore/SourceMatcher
// record — including a real sequence of source switches, guesses and pins.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

class _Src implements SourceRepository {
  _Src(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      bySource[sourceId] ?? const [];
}

MediaItem _hit(String src, String title) => MediaItem(
  id: title.toLowerCase(), title: title, url: 'https://$src/$title',
  type: ProviderType.anime, sourceId: src);

void main() {
  late Directory dir;
  const c = ZCanonical(ZKind.anime, 'mal:5114');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('progress_invariance');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('the zm:// identity a title plays under never depends on the matched source', () async {
    // What PlayerController/ResumeStore/WatchHistory actually key on for a
    // Z Mode item: ZmodeIds.sourceId ('zm') + the canonical's own zm:// urls.
    final sourceIdBefore = ZmodeIds.sourceId;
    final showUrlBefore = ZmodeIds.showUrl(c);
    final episodeUrlBefore = ZmodeIds.episodeUrl(c, 7);

    final store = await MatchStore.open();
    final src = _Src({
      'allanime': [_hit('allanime', 'Fullmetal Alchemist Brotherhood')],
      'hianime': [_hit('hianime', 'Fullmetal Alchemist Brotherhood')],
    });
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      candidates: (_) => [(id: 'allanime', name: 'AllAnime'), (id: 'hianime', name: 'HiAnime')],
    );

    // A realistic sequence: auto-resolve, switch source, pin a correction —
    // everything this task's selector/"Wrong title?" can do to a title.
    await matcher.resolve(c, title: 'Fullmetal Alchemist: Brotherhood');
    expect(store.selectedSource(c), 'allanime');

    await store.selectSource(c, 'hianime');
    await matcher.resolve(c, title: 'Fullmetal Alchemist: Brotherhood');
    expect(store.selectedSource(c), 'hianime');

    await matcher.pinManual(c, _hit('allanime', 'Fullmetal Alchemist Brotherhood (2003)'));
    expect(store.selectedSource(c), 'allanime');

    // None of that touched the identity progress is keyed on.
    expect(ZmodeIds.sourceId, sourceIdBefore);
    expect(ZmodeIds.showUrl(c), showUrlBefore);
    expect(ZmodeIds.episodeUrl(c, 7), episodeUrlBefore);
    // And that identity depends only on the canonical, never on the resolved
    // SourceMatch — a fresh ZCanonical with no MatchStore entry at all
    // produces byte-identical urls to the one that's been switched/pinned
    // three times over.
    const fresh = ZCanonical(ZKind.anime, 'mal:5114');
    expect(ZmodeIds.showUrl(fresh), showUrlBefore);
    expect(ZmodeIds.episodeUrl(fresh, 7), episodeUrlBefore);
  });

  test('resolve()/pinManual() never mutate the canonical they are given', () async {
    // A structural guarantee behind the above: SourceMatcher only ever reads
    // c.kind/c.id (via c.key) — ZCanonical has no mutable fields for it to
    // change, so "the title" can never drift as a side effect of matching.
    final store = await MatchStore.open();
    final src = _Src({'allanime': [_hit('allanime', 'FMA')]});
    final matcher = SourceMatcher(
        sources: src, store: store, candidates: (_) => [(id: 'allanime', name: 'AllAnime')]);
    final keyBefore = c.key;
    await matcher.resolve(c, title: 'FMA');
    await matcher.pinManual(c, _hit('allanime', 'FMA'));
    expect(c.key, keyBefore);
  });
}
