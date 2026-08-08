import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

/// M7 wiring net for `SourceRepository`: proves a `mihon:` id actually routes
/// to its [MihonProvider], and proves the anime (`ani:`) routing next to it is
/// untouched by that.
///
/// Every assertion checks a real routing OUTCOME — which provider answered,
/// which native method went out over the channel, which items came back — not
/// merely that a call didn't throw.

const _channel = MethodChannel('zangetsu/mihon');

MihonSourceInfo _info({
  int id = 7,
  String name = 'MangaSrc',
  String baseUrl = 'https://m.example.com',
  bool nsfw = false,
}) => MihonSourceInfo(
  id: id,
  name: name,
  lang: 'en',
  baseUrl: baseUrl,
  pkg: 'com.test.manga',
  nsfw: nsfw,
);

AniyomiSourceInfo _aniInfo({int id = 1, String name = 'AnimeSrc'}) =>
    AniyomiSourceInfo(
      id: id,
      name: name,
      lang: 'en',
      baseUrl: 'https://a.example.com',
      pkg: 'com.test.anime',
      nsfw: false,
    );

/// Records which paging method the repository called, so `browseMore`'s new
/// cases are proven to hit `popular`/`latest` specifically — not just "some
/// non-empty list came back".
class _RecordingMihonProvider extends MihonProvider {
  _RecordingMihonProvider(int id) : super(info: _info(id: id));

  String? calledMethod;
  int? calledPage;

  MediaItem _sentinel(String tag) => MediaItem(
    id: tag,
    title: tag,
    url: 'https://fake.test/$tag',
    type: ProviderType.manga,
    sourceId: sourceId,
  );

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    calledMethod = 'popular';
    calledPage = page;
    return [_sentinel('popular')];
  }

  @override
  Future<List<MediaItem>> latest({int page = 1}) async {
    calledMethod = 'latest';
    calledPage = page;
    return [_sentinel('latest')];
  }
}

SourceRepository _repoWith({
  MihonManager? mihon,
  AniyomiManager? ani,
  PlaybackPrefs? prefs,
}) => SourceRepository(
  manager: ProviderManager(dio: Dio()),
  csManager: CloudStreamManager(),
  aniManager: ani ?? AniyomiManager(),
  mihonManager: mihon,
  activeSource: ActiveSourceCubit(),
  prefs: prefs ?? PlaybackPrefs(),
);

void main() {
  // ProviderManager eagerly spins up the QuickJS runtime in its constructor.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  // loadedSources reads the NSFW prefs, which are Hive-backed.
  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('mihon_routing_test');
    Hive.init(tempDir.path);
    await PlaybackPrefs.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  final log = <MethodCall>[];

  void mockChannel(Future<dynamic> Function(MethodCall call) handler) {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          log.add(call);
          return handler(call);
        });
  }

  tearDown(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('_providerFor resolves the mihon: prefix', () {
    test('a mihon: id routes to the MihonProvider, not the JS manager', () async {
      mockChannel((call) async {
        if (call.method == 'getChapters') {
          return jsonEncode([
            {'url': '/c1', 'name': 'Chapter 1', 'chapter_number': 1.0},
          ]);
        }
        return null;
      });
      final mihon = MihonManager()..register(MihonProvider(info: _info(id: 7)));
      final repo = _repoWith(mihon: mihon);

      // Reaching the provider at all is the routing proof: an unresolved id
      // throws StateError('Provider not loaded') out of _providerFor.
      final chapters = await repo.episodes('/manga-1', sourceId: 'mihon:7');

      expect(log.single.method, 'getChapters');
      expect((log.single.arguments as Map)['sourceId'], 7);
      expect(chapters.single.title, 'Chapter 1');
    });

    test('an unregistered mihon: id still throws StateError', () {
      final repo = _repoWith(mihon: MihonManager());
      expect(
        () => repo.episodes('/x', sourceId: 'mihon:999'),
        throwsA(isA<StateError>()),
      );
    });

    test('omitting mihonManager entirely leaves mihon: ids unresolvable', () {
      // The ctor param is optional so no existing call site had to change —
      // this pins the resulting behaviour: an EMPTY registry, never a crash
      // and never a silent fallback to some other provider.
      final repo = _repoWith();
      expect(repo.hasSource('mihon:7'), isFalse);
      expect(
        () => repo.episodes('/x', sourceId: 'mihon:7'),
        throwsA(isA<StateError>()),
      );
    });

    test('displayName / hasSource / baseUrlFor answer for a mihon: id', () {
      final mihon = MihonManager()
        ..register(
          MihonProvider(
            info: _info(id: 7, name: 'MangaDex', baseUrl: 'https://md.test'),
          ),
        );
      final repo = _repoWith(mihon: mihon);

      expect(repo.displayName('mihon:7'), 'MangaDex');
      expect(repo.hasSource('mihon:7'), isTrue);
      expect(repo.hasSource('mihon:8'), isFalse);
      // Mihon item urls are paths, so the base url is needed to build a link.
      expect(repo.baseUrlFor('mihon:7'), 'https://md.test');
    });
  });

  group('loadedSources', () {
    test('lists mihon sources alongside aniyomi ones', () {
      final ani = AniyomiManager()
        ..register(AniyomiProvider(info: _aniInfo(id: 1, name: 'HiAnime')));
      final mihon = MihonManager()
        ..register(MihonProvider(info: _info(id: 7, name: 'MangaDex')));
      final repo = _repoWith(mihon: mihon, ani: ani);

      final ids = repo.loadedSources.map((s) => s.id).toList();
      expect(ids, contains('mihon:7'));
      expect(ids, contains('ani:1'));
      expect(
        repo.loadedSources.firstWhere((s) => s.id == 'mihon:7').name,
        'MangaDex',
      );
    });

    test('an NSFW mihon source is hidden while the nsfwSources pref is off', () async {
      final prefs = PlaybackPrefs();
      await prefs.setNsfwSources(false);
      final mihon = MihonManager()
        ..register(MihonProvider(info: _info(id: 7, nsfw: true)))
        ..register(MihonProvider(info: _info(id: 8, nsfw: false)));

      var ids = _repoWith(
        mihon: mihon,
        prefs: prefs,
      ).loadedSources.map((s) => s.id);
      expect(ids, contains('mihon:8'));
      expect(ids, isNot(contains('mihon:7')));

      await prefs.setNsfwSources(true);
      ids = _repoWith(mihon: mihon, prefs: prefs).loadedSources.map((s) => s.id);
      expect(ids, contains('mihon:7'));

      await prefs.setNsfwSources(false); // leave the box as we found it
    });
  });

  group('browseMore — the two Mihon kinds', () {
    test('mihon_popular routes to popular(page:) and returns items', () async {
      final p = _RecordingMihonProvider(7);
      final repo = _repoWith(mihon: MihonManager()..register(p));

      final res = await repo.browseMore(
        BrowseMore(sourceId: p.sourceId, kind: 'mihon_popular'),
        2,
      );

      expect(p.calledMethod, 'popular');
      expect(p.calledPage, 2);
      // The bug this case fixes was "See all" rendering an EMPTY grid, so the
      // returned list — not just the call — is what matters.
      expect(res, isNotEmpty);
      expect(res.single.id, 'popular');
    });

    test('mihon_latest routes to latest(page:) and returns items', () async {
      final p = _RecordingMihonProvider(8);
      final repo = _repoWith(mihon: MihonManager()..register(p));

      final res = await repo.browseMore(
        BrowseMore(sourceId: p.sourceId, kind: 'mihon_latest'),
        3,
      );

      expect(p.calledMethod, 'latest');
      expect(p.calledPage, 3);
      expect(res, isNotEmpty);
      expect(res.single.id, 'latest');
    });

    test('the kinds MihonProvider.getHome actually emits are the wired ones', () async {
      // Guards against the two sides drifting apart: a renamed kind on either
      // side silently reverts "See all" to an empty grid.
      mockChannel((call) async {
        if (call.method == 'getPopular' || call.method == 'getLatest') {
          return jsonEncode([
            {'url': '/m1', 'title': 'Manga One'},
          ]);
        }
        return null;
      });
      final provider = MihonProvider(info: _info(id: 7));
      final sections = await provider.getHome();
      final kinds = sections!.map((s) => s.more!.kind).toList();
      expect(kinds, ['mihon_popular', 'mihon_latest']);

      final repo = _repoWith(mihon: MihonManager()..register(provider));
      for (final kind in kinds) {
        final res = await repo.browseMore(
          BrowseMore(sourceId: provider.sourceId, kind: kind),
          1,
        );
        expect(res, isNotEmpty, reason: '$kind fell through to default: []');
      }
    });

    test('mihon_latest on a non-Mihon provider degrades to []', () async {
      final ani = AniyomiManager()..register(AniyomiProvider(info: _aniInfo()));
      final repo = _repoWith(ani: ani);
      final res = await repo.browseMore(
        const BrowseMore(sourceId: 'ani:1', kind: 'mihon_latest'),
        1,
      );
      expect(res, isEmpty);
    });
  });

  group('reading leaves reach MihonProvider', () {
    test('pages() returns the provider\'s pages, not UnsupportedError', () async {
      mockChannel((call) async {
        if (call.method == 'getPages') {
          return jsonEncode([
            {'index': 0, 'url': '/c1/p1', 'imageUrl': 'https://cdn/p1.jpg'},
            {'index': 1, 'url': '/c1/p2', 'imageUrl': 'https://cdn/p2.jpg'},
          ]);
        }
        return null;
      });
      final mihon = MihonManager()..register(MihonProvider(info: _info(id: 7)));
      final repo = _repoWith(mihon: mihon);

      final pages = await repo.pages('/c1', sourceId: 'mihon:7');

      expect(log.single.method, 'getPages');
      expect(pages.map((p) => p.url), [
        'https://cdn/p1.jpg',
        'https://cdn/p2.jpg',
      ]);
    });

    test(
      'chapterText() reaches the provider — the throw is MihonProvider\'s, '
      'not the repository\'s ReadingProvider guard',
      () async {
        final mihon = MihonManager()
          ..register(MihonProvider(info: _info(id: 7)));
        final repo = _repoWith(mihon: mihon);

        // MihonProvider IS a ReadingProvider, so the repository's
        // `is! ReadingProvider` guard must NOT fire. It still throws — Mihon is
        // manga-only — but with the provider's own message. Matching the
        // message is what distinguishes "routed correctly" from "not routed".
        // (Thrown synchronously: neither chapterText nor getText is `async`.)
        expect(
          () => repo.chapterText('/c1', sourceId: 'mihon:7'),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains('MihonProvider is manga-only'),
            ),
          ),
        );
      },
    );
  });

  group('anime routing is unchanged', () {
    test('ani_popular / ani_latest still route to the Aniyomi provider', () async {
      final ani = AniyomiManager()..register(_RecordingAniProvider(1));
      final p = ani.get('ani:1') as _RecordingAniProvider;
      final repo = _repoWith(ani: ani, mihon: MihonManager());

      expect(
        (await repo.browseMore(
          const BrowseMore(sourceId: 'ani:1', kind: 'ani_popular'),
          2,
        )).single.id,
        'popular',
      );
      expect(p.calledPage, 2);

      expect(
        (await repo.browseMore(
          const BrowseMore(sourceId: 'ani:1', kind: 'ani_latest'),
          5,
        )).single.id,
        'latest',
      );
      expect(p.calledPage, 5);
    });

    test('an unknown kind still returns [] (default arm intact)', () async {
      final ani = AniyomiManager()..register(_RecordingAniProvider(1));
      final repo = _repoWith(ani: ani, mihon: MihonManager());
      expect(
        await repo.browseMore(
          const BrowseMore(sourceId: 'ani:1', kind: 'totally_unknown'),
          1,
        ),
        isEmpty,
      );
    });

    test('a registered MihonManager does not shadow ani:/js: resolution', () {
      final ani = AniyomiManager()
        ..register(AniyomiProvider(info: _aniInfo(id: 1, name: 'HiAnime')));
      final mihon = MihonManager()
        ..register(MihonProvider(info: _info(id: 1, name: 'MangaDex')));
      final repo = _repoWith(ani: ani, mihon: mihon);

      // Same numeric id on both sides — the prefix, not the number, decides.
      expect(repo.displayName('ani:1'), 'HiAnime');
      expect(repo.displayName('mihon:1'), 'MangaDex');
      expect(repo.baseUrlFor('ani:1'), 'https://a.example.com');
      expect(repo.hasSource('ani:1'), isTrue);
      expect(repo.hasSource('js:whatever'), isFalse);
    });

    test('aniFilters still ignores non-Aniyomi ids, incl. mihon:', () async {
      final repo = _repoWith(
        mihon: MihonManager()..register(MihonProvider(info: _info(id: 7))),
      );
      expect(await repo.aniFilters('mihon:7'), isEmpty);
      expect(await repo.aniFilters('cs:whatever'), isEmpty);
    });

    test('mihonFilters ignores non-Mihon ids', () async {
      final ani = AniyomiManager()..register(AniyomiProvider(info: _aniInfo()));
      final repo = _repoWith(ani: ani);
      expect(await repo.mihonFilters('ani:1'), isEmpty);
    });
  });

  group('filters reach the Mihon provider', () {
    test('searchStatus forwards filtersJson into the native search call', () async {
      // The failure mode this pins is silent: without the mihon arm in
      // _searchStatusUncached the call falls through to the 3-arg
      // provider.search(), the selection is dropped, and the search still
      // succeeds — so nothing surfaces until someone notices on device that
      // filters do nothing. Asserting the `filters` ARGUMENT on the wire is
      // what makes that regression fail here.
      mockChannel((call) async {
        if (call.method == 'search') {
          return jsonEncode([
            {'url': '/m1', 'title': 'Manga One'},
          ]);
        }
        return null;
      });
      final mihon = MihonManager()..register(MihonProvider(info: _info(id: 7)));
      final repo = _repoWith(mihon: mihon);

      const selection = '[{"type":"select","state":2}]';
      final res = await repo.searchStatus(
        'dragon',
        sourceId: 'mihon:7',
        filtersJson: selection,
      );

      expect(log.single.method, 'search');
      final args = log.single.arguments as Map;
      expect(args['sourceId'], 7);
      expect(args['query'], 'dragon');
      expect(args['filters'], selection);
      expect(res.outcome, SourceOutcome.ok);
      expect(res.items, hasLength(1));
    });

    test('searchStatus without filtersJson sends no filters key', () async {
      mockChannel((call) async => call.method == 'search' ? '[]' : null);
      final mihon = MihonManager()..register(MihonProvider(info: _info(id: 7)));
      final repo = _repoWith(mihon: mihon);

      await repo.searchStatus('dragon', sourceId: 'mihon:7');

      expect((log.single.arguments as Map).containsKey('filters'), isFalse);
    });

    test('mihonFilters returns the provider\'s parsed schema', () async {
      // Covers the `p is MihonProvider ? p.getFilters()` arm, not just the
      // non-Mihon early return.
      mockChannel((call) async {
        if (call.method == 'getFilterList') {
          return jsonEncode([
            {'type': 'header', 'name': 'Genres'},
            {'type': 'checkbox', 'name': 'Action', 'state': true},
          ]);
        }
        return null;
      });
      final mihon = MihonManager()..register(MihonProvider(info: _info(id: 7)));
      final repo = _repoWith(mihon: mihon);

      final filters = await repo.mihonFilters('mihon:7');

      expect(log.single.method, 'getFilterList');
      expect((log.single.arguments as Map)['sourceId'], 7);
      expect(filters, hasLength(2));
      expect(filters.map((f) => f.name), ['Genres', 'Action']);
    });
  });
}

/// Aniyomi twin of [_RecordingMihonProvider], so the "anime is unchanged"
/// group asserts real routing rather than assuming it.
class _RecordingAniProvider extends AniyomiProvider {
  _RecordingAniProvider(int id) : super(info: _aniInfo(id: id));

  int? calledPage;

  MediaItem _sentinel(String tag) => MediaItem(
    id: tag,
    title: tag,
    url: 'https://fake.test/$tag',
    type: ProviderType.anime,
    sourceId: sourceId,
  );

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    calledPage = page;
    return [_sentinel('popular')];
  }

  @override
  Future<List<MediaItem>> latest({int page = 1}) async {
    calledPage = page;
    return [_sentinel('latest')];
  }
}
