// Tapping a title in a source's own browse screen should land on the SAME show
// Home opens, with that source pinned for it. Every failure has to fall back
// to opening the source's own item, because a source-only title still has to
// be watchable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

Map<String, dynamic> _al({String romaji = 'Fullmetal Alchemist'}) => {
  'id': 1,
  'idMal': 100,
  'title': {'romaji': romaji, 'english': null},
  'coverImage': {'large': 'c'},
  'episodes': 64,
  'chapters': null,
  'status': 'FINISHED',
  'genres': <String>[],
  'description': null,
  'seasonYear': 2009,
  'studios': {'nodes': <dynamic>[]},
  'nextAiringEpisode': null,
};

class _Src implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => true;
}

const _tapped = MediaItem(
  id: 'fma',
  title: 'Fullmetal Alchemist',
  url: 'https://hianime/fma',
  type: ProviderType.anime,
  sourceId: 'hianime',
);

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;

  Future<void> registerCatalogue({
    List<Map<String, dynamic>> results = const [],
    Duration delay = Duration.zero,
  }) async {
    final src = _Src();
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => [
        (id: 'allanime', name: 'AllAnime'),
        (id: 'hianime', name: 'HiAnime'),
      ],
    );
    sl.registerSingleton<SourceMatcher>(matcher);
    sl.registerSingleton<MetadataRepository>(
      MetadataRepository(
        anilist: AniListCatalogue((q, v) async {
          if (delay > Duration.zero) await Future<void>.delayed(delay);
          return {'Page': {'media': results}};
        }),
        tmdb: TmdbCatalogue((p, q) async => {'results': []}),
        sources: src,
        matcher: matcher,
      matchStore: await MatchStore.open(),
      sourcePrefs: await ZSourcePrefs.open(),
        browseKind: () => ZKind.anime,
      ),
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('browse_link');
    Hive.init(dir.path);
    await ZModePrefs.init();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });

  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a recognised title resolves to the catalogue show', () async {
    await registerCatalogue(results: [_al()]);
    final target = await canonicalTargetFor(_tapped);
    expect(target?.url, 'zm://anime/mal:100');
  });

  test('and the browsed source is pinned for that title only', () async {
    await registerCatalogue(results: [_al()]);
    await canonicalTargetFor(_tapped);

    const fma = ZCanonical(ZKind.anime, 'mal:100');
    expect(store.pinnedFor(fma)?.sourceId, 'hianime');
    expect(store.pinnedFor(fma)?.showUrl, 'https://hianime/fma');
    // The kind default is untouched: browsing one source is not a decision
    // about every other show.
    expect(prefs.get(ZKind.anime), isNull);
  });

  test('a title the catalogue does not know opens as the source item',
      () async {
    await registerCatalogue(results: [_al(romaji: 'Something Else')]);
    expect(await canonicalTargetFor(_tapped), isNull);
    expect(store.pinnedFor(const ZCanonical(ZKind.anime, 'mal:100')), isNull);
  });

  test('with no catalogue registered it opens as the source item', () async {
    expect(await canonicalTargetFor(_tapped), isNull);
  });

  test('a slow catalogue gives up and opens the source item', () async {
    // The user tapped a poster; they must not be left waiting on a metadata
    // API that is hanging.
    await registerCatalogue(results: [_al()], delay: const Duration(seconds: 6));
    final sw = Stopwatch()..start();

    final target = await canonicalTargetFor(_tapped);

    expect(target, isNull);
    // Bounded, and bounded SHORT: this sits between a tap and a screen.
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('the screen stays quiet for a beat before it says anything', () {
    // A bar that flashes for 200ms is worse than no bar, and most lookups
    // finish inside this.
    expect(kLinkingIndicatorDelay.inMilliseconds, lessThan(500));
    expect(kLinkingIndicatorDelay, lessThan(kCanonicalLookupTimeout));
  });
}
