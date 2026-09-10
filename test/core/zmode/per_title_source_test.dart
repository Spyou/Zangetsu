// A show remembers its own source. Until now the app had one source per kind,
// so choosing a source for one title silently chose it for every title of that
// kind, and a pin on any other source was never read back.
//
// The failure this guards is quiet: the picker names one source, playback uses
// another, and nothing says which of the two is real.

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
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      bySource[sourceId] ?? const [];
}

MediaItem _hit(String src, String title) => MediaItem(
      id: title.toLowerCase(),
      title: title,
      url: 'https://$src/$title',
      type: ProviderType.anime,
      sourceId: src,
    );

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceMatcher matcher;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  const other = ZCanonical(ZKind.anime, 'mal:21');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('per_title_source');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    matcher = SourceMatcher(
      sources: _Src({
        'allanime': [_hit('allanime', 'FMA')],
        'hianime': [_hit('hianime', 'FMA')],
      }),
      store: store,
      prefs: prefs,
      candidates: (_) => [
        (id: 'allanime', name: 'AllAnime'),
        (id: 'hianime', name: 'HiAnime'),
      ],
    );
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('MatchStore.pinnedFor', () {
    test('is null until the user chooses', () async {
      await store.save(fma, const SourceMatch(
        sourceId: 'allanime', showUrl: 'https://a/fma', showId: 'fma',
        showTitle: 'FMA', pinned: false));
      expect(store.pinnedFor(fma), isNull);
    });

    test('finds a pin on ANY source, not just the default one', () async {
      await store.pin(fma, const SourceMatch(
        sourceId: 'hianime', showUrl: 'https://h/fma', showId: 'fma-h',
        showTitle: 'FMA', pinned: false));
      expect(store.pinnedFor(fma)?.sourceId, 'hianime');
    });

    test('a second pin replaces the first, never leaves two', () async {
      // Two pinned entries would make the answer depend on Hive key order,
      // so the title would follow whichever source the box happened to list.
      await store.pin(fma, const SourceMatch(
        sourceId: 'hianime', showUrl: 'https://h/fma', showId: 'h',
        showTitle: 'FMA', pinned: false));
      await store.pin(fma, const SourceMatch(
        sourceId: 'allanime', showUrl: 'https://a/fma', showId: 'a',
        showTitle: 'FMA', pinned: false));

      expect(store.pinnedFor(fma)?.sourceId, 'allanime');
      expect(store.get(fma, 'hianime')?.pinned, isFalse);
      // Demoted, not deleted — it is still a good remembered match.
      expect(store.get(fma, 'hianime')?.showUrl, 'https://h/fma');
    });

    test('a pin belongs to one title only', () async {
      await store.pin(fma, const SourceMatch(
        sourceId: 'hianime', showUrl: 'https://h/fma', showId: 'h',
        showTitle: 'FMA', pinned: false));
      expect(store.pinnedFor(other), isNull);
    });

    test('unpinAll hands the title back to the kind default', () async {
      await store.pin(fma, const SourceMatch(
        sourceId: 'hianime', showUrl: 'https://h/fma', showId: 'h',
        showTitle: 'FMA', pinned: false));
      await store.unpinAll(fma);
      expect(store.pinnedFor(fma), isNull);
      expect(store.get(fma, 'hianime')?.showUrl, 'https://h/fma');
    });
  });

  group('SourceMatcher.sourceForTitle', () {
    test('falls back to the kind default when nothing is pinned', () async {
      await prefs.set(ZKind.anime, 'allanime');
      expect(matcher.sourceForTitle(fma), 'allanime');
    });

    test('the pinned source wins over the kind default', () async {
      await prefs.set(ZKind.anime, 'allanime');
      await matcher.pinForTitle(fma, _hit('hianime', 'FMA'));
      expect(matcher.sourceForTitle(fma), 'hianime');
      // …and only for this title.
      expect(matcher.sourceForTitle(other), 'allanime');
    });

    test('resolve() plays the pinned source, not the default', () async {
      await prefs.set(ZKind.anime, 'allanime');
      await matcher.pinForTitle(fma, _hit('hianime', 'FMA'));
      final m = await matcher.resolve(fma, title: 'FMA');
      expect(m?.sourceId, 'hianime');
    });

    test('saved() reads the pinned source too', () async {
      await prefs.set(ZKind.anime, 'allanime');
      await matcher.pinForTitle(fma, _hit('hianime', 'FMA'));
      expect(matcher.saved(fma)?.sourceId, 'hianime');
    });

    test('clearTitlePin puts the title back on the default', () async {
      await prefs.set(ZKind.anime, 'allanime');
      await matcher.pinForTitle(fma, _hit('hianime', 'FMA'));
      await matcher.clearTitlePin(fma);
      expect(matcher.sourceForTitle(fma), 'allanime');
    });
  });

  group('chooseSource (the picker)', () {
    test('clears the title pin AND moves the kind default', () async {
      // Both halves matter: without the first the pick is ignored on this very
      // title, without the second it is forgotten on every other one.
      await prefs.set(ZKind.anime, 'allanime');
      await matcher.pinForTitle(fma, _hit('hianime', 'FMA'));

      await matcher.chooseSource(fma, 'allanime');

      expect(store.pinnedFor(fma), isNull);
      expect(prefs.get(ZKind.anime), 'allanime');
      expect(matcher.sourceForTitle(fma), 'allanime');
    });
  });

  group('pinForTitle vs pinManual', () {
    test('pinForTitle leaves the kind default alone', () async {
      // This is the whole point: browsing a source and opening a show there is
      // a choice about that show. If this ever sets the kind default again,
      // one tap silently re-points every other title of the kind.
      await prefs.set(ZKind.anime, 'allanime');
      await matcher.pinForTitle(fma, _hit('hianime', 'FMA'));
      expect(prefs.get(ZKind.anime), 'allanime');
    });

    test('pinManual leaves the kind default alone too', () async {
      // Correcting one show's match used to re-point every other anime and
      // movie at that source — and since a kind default is honoured as-is,
      // that switched Auto Resolve off for all of them.
      await prefs.set(ZKind.anime, 'allanime');
      await matcher.pinManual(fma, _hit('hianime', 'FMA'));
      expect(prefs.get(ZKind.anime), 'allanime');
      // This title still follows the correction, via its own pin.
      expect(matcher.sourceForTitle(fma), 'hianime');
    });
  });
}
