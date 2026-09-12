// Switching a manga or novel to another source has to switch the CHAPTERS
// with it. Both halves of that can fail quietly: the picker names the source
// you chose either way, so a stale list reads as this source's chapters until
// you open one and get someone else's.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

class _Src implements SourceRepository {
  _Src(this.bySource);

  /// sourceId -> what its search returns. A source absent from this map is
  /// installed but has nothing for the title.
  final Map<String, List<MediaItem>> bySource;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async => bySource[sourceId] ?? const [];
}

MediaItem _hit(String src, String title) => MediaItem(
  id: '$src-id',
  title: title,
  url: 'https://$src/$title',
  type: ProviderType.manga,
  sourceId: src,
);

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;

  const manga = ZCanonical(ZKind.manga, 'mal:11');
  const novel = ZCanonical(ZKind.novel, 'mal:22');
  const title = 'The Swordmasters Son';

  /// [only] names the sources that actually have the title.
  SourceMatcher matcherWith(List<String> only) => SourceMatcher(
    sources: _Src({for (final s in only) s: [_hit(s, title)]}),
    store: store,
    prefs: prefs,
    candidates: (_) => const [
      (id: 'mihon:dex', name: 'MangaDex'),
      (id: 'mihon:nato', name: 'MangaNato'),
      (id: 'lnr:a', name: 'Novel A'),
      (id: 'lnr:b', name: 'Novel B'),
    ],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source_switch');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('both sources have it', () {
    test('manga: the chapters follow the new source', () async {
      final m = matcherWith(['mihon:dex', 'mihon:nato']);

      await m.pinTitleToSource(manga, 'mihon:dex', title: title);
      expect(
        (await m.resolve(manga, title: title))!.showUrl,
        contains('mihon:dex'),
      );

      await m.pinTitleToSource(manga, 'mihon:nato', title: title);
      expect(
        (await m.resolve(manga, title: title))!.showUrl,
        contains('mihon:nato'),
        reason: 'still serving the old source after the switch',
      );
    });

    test('novel: same, since both run the same branch', () async {
      final m = matcherWith(['lnr:a', 'lnr:b']);

      await m.pinTitleToSource(novel, 'lnr:a', title: title);
      await m.pinTitleToSource(novel, 'lnr:b', title: title);

      expect((await m.resolve(novel, title: title))!.showUrl, contains('lnr:b'));
    });
  });

  group('the new source does NOT have it', () {
    test('manga: it must not fall back to the old source', () async {
      // What the tester hit: picked Atsumaru, which has nothing for this
      // title, and the previous source's chapters stayed on screen under the
      // new source's name. Tapping one reads from a source the UI isn't
      // showing.
      final m = matcherWith(['mihon:dex']); // nato has nothing

      await m.pinTitleToSource(manga, 'mihon:dex', title: title);
      await m.pinTitleToSource(manga, 'mihon:nato', title: title);

      final after = await m.resolve(manga, title: title);
      expect(
        after?.sourceId,
        isNot('mihon:dex'),
        reason: 'the picker says MangaNato while MangaDex serves the chapters',
      );
      // And it must be no match at all, not a hollow one: detail() feeds
      // showUrl straight to episodes(), so an empty match fetches chapters
      // from nowhere instead of showing the empty list the screen expects.
      expect(after, isNull);
    });

    test('the choice survives, so it does not sweep back to the old one',
        () async {
      final m = matcherWith(['mihon:dex']);

      await m.pinTitleToSource(manga, 'mihon:dex', title: title);
      await m.pinTitleToSource(manga, 'mihon:nato', title: title);

      // Not "unpin and fall back to Auto Resolve" — that sweeps and lands on
      // MangaDex again, which is the thing the user just moved away from.
      expect(m.sourceForTitle(manga), 'mihon:nato');
    });

    test('it asks again next time rather than caching the nothing', () async {
      // A source that gains the title later (or was just blocked at that
      // moment) has to be able to answer on a later open.
      final m = matcherWith(['mihon:dex']);
      await m.pinTitleToSource(manga, 'mihon:nato', title: title);

      final later = matcherWith(['mihon:dex', 'mihon:nato']);
      expect(
        (await later.resolve(manga, title: title))?.showUrl,
        contains('mihon:nato'),
      );
    });

    test('a failed pick still announces the change', () async {
      // Same callback the successful path fires: it drops the resolver's
      // cached winners for this show. pinTitleToSource is shared with video,
      // where a stale winner keeps playing the old source's episode.
      final m = matcherWith(['mihon:dex']);
      final told = <ZCanonical>[];
      m.bindSourceChanged(told.add);

      await m.pinTitleToSource(manga, 'mihon:nato', title: title);

      expect(told, [manga]);
    });

    test('novel: same', () async {
      final m = matcherWith(['lnr:a']); // b has nothing

      await m.pinTitleToSource(novel, 'lnr:a', title: title);
      await m.pinTitleToSource(novel, 'lnr:b', title: title);

      final after = await m.resolve(novel, title: title);
      expect(after?.sourceId, isNot('lnr:a'));
      expect(after, isNull);
    });
  });
}
