// End-to-end proof that a Z Mode subscription is resolved by the REAL wiring.
//
// The earlier routing test used a stand-in router, which only showed the
// checker asks whatever it is handed. This builds the actual CatalogueRouter
// over the actual MetadataRepository, with a fake only at the far edge (the
// source that owns the episodes), and asserts a `zm://` subscription reaches
// it. Swap the checker back to SourceRepository and this fails.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/notify/subscription_checker.dart';
import 'package:watch_app/core/notify/subscription_store.dart';
import 'package:watch_app/core/repository/catalogue_router.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// The source that actually owns the episodes. Everything above this is real.
class _Src implements SourceRepository {
  _Src(this.episodeCount);
  final int episodeCount;
  String? askedUrl;
  String? askedSourceId;

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    askedUrl = url;
    askedSourceId = sourceId;
    // What the real SourceRepository does with an id it has no provider for
    // — this is the exact throw that the old wiring hit for every `zm` sub.
    if (sourceId != 'ani:1') {
      throw StateError('Provider not loaded: $sourceId');
    }
    return [
      for (var i = 0; i < episodeCount; i++)
        Episode(id: '$i', number: i + 1, title: 'Ep ${i + 1}', url: '$url/$i'),
    ];
  }

  @override
  bool hasSource(String sourceId) => sourceId == 'ani:1';

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async => const [];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('realroute');
    Hive.init(dir.path);
    await SubscriptionStore.init();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a zm:// subscription reaches the matched source through the router',
      () async {
    const canonical = ZCanonical(ZKind.anime, 'mal:1735');
    final url = ZmodeIds.showUrl(canonical);

    final src = _Src(12);
    final store = await MatchStore.open();
    final prefs = await ZSourcePrefs.open();
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => [(id: 'ani:1', name: 'A Source')],
    );
    // The title already has a source matched, as it would after being opened.
    await matcher.selectSource(ZKind.anime, 'ani:1');
    await store.save(
      canonical,
      const SourceMatch(
        sourceId: 'ani:1',
        showUrl: 'https://src.test/show/1',
        showId: '1',
        showTitle: 'Naruto',
        pinned: true,
      ),
    );

    final metadata = MetadataRepository(
      anilist: AniListCatalogue((q, v) async => {
        'Media': {'id': 1735, 'idMal': 1735, 'title': {'romaji': 'Naruto'}},
      }),
      tmdb: TmdbCatalogue((p, q) async => {'results': []}),
      sources: src,
      matcher: matcher,
      browseKind: () => ZKind.anime,
    );

    final router = CatalogueRouter(
      source: src,
      metadata: metadata,
      enabled: () => true,
    );

    final subs = SubscriptionStore();
    await subs.add(Subscription(
      sourceId: ZmodeIds.sourceId,
      url: url,
      title: 'Naruto',
      lastCount: 3,
      mode: ContentMode.anime,
    ));

    await SubscriptionChecker(router, subs).checkAll();

    // The proof: the far-edge source was asked for ITS url, which only
    // happens if the router sent zm:// to the metadata repository and that
    // resolved the match.
    expect(src.askedUrl, 'https://src.test/show/1');
    expect(src.askedSourceId, 'ani:1');
    // And the new count was written back, which only happens on success.
    expect(subs.all().single.lastCount, 12);
  });

  test('the OLD wiring silently checks nothing — the bug, reproduced', () async {
    const canonical = ZCanonical(ZKind.anime, 'mal:1735');
    final url = ZmodeIds.showUrl(canonical);
    final src = _Src(12);

    final subs = SubscriptionStore();
    await subs.add(Subscription(
      sourceId: ZmodeIds.sourceId,
      url: url,
      title: 'Naruto',
      lastCount: 3,
      mode: ContentMode.anime,
    ));

    // Handing the checker the source repository directly is what shipped.
    await SubscriptionChecker(src, subs).checkAll();

    // It asked the source for the zm url, which throws, and the sweep
    // swallowed it: the count never moved, so no notification could ever fire.
    expect(src.askedSourceId, ZmodeIds.sourceId);
    expect(subs.all().single.lastCount, 3, reason: 'never checked');
  });
}
