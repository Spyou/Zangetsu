import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

/// M7 wiring net for `source_switcher.dart`: a `mihon:` id must type as MANGA
/// in both [sourceTypeOf] and its precomputed-map twin, and `ani:` must still
/// type as ANIME right beside it (spec Decision 1 — a separate prefix is
/// exactly why the anime line never has to change).

class _FakeManager implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  void load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) {}
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}
  @override
  void remove(String id) {}
}

class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async =>
      CachedProvider(name: name, jsCode: '', url: url, fetchedAt: DateTime.now());
  @override
  Future<void> remove(String name) async {}
}

MihonSourceInfo _mihonInfo({
  int id = 42,
  String name = 'MangaDex',
  bool nsfw = false,
  String lang = 'en',
}) => MihonSourceInfo(
  id: id,
  name: name,
  lang: lang,
  baseUrl: 'https://md.test',
  pkg: 'com.test.manga',
  nsfw: nsfw,
);

AniyomiSourceInfo _aniInfo({int id = 1, String name = 'HiAnime'}) =>
    AniyomiSourceInfo(
      id: id,
      name: name,
      lang: 'en',
      baseUrl: 'https://a.test',
      pkg: 'com.test.anime',
      nsfw: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sourceTypeOf — prefix routing (no GetIt needed for mihon:)', () {
    test('a mihon: id is MANGA', () {
      expect(sourceTypeOf('mihon:42'), ProviderType.manga);
      expect(sourceTypeOf('mihon:0'), ProviderType.manga);
    });

    test('an ani: id is still ANIME — the anime branch is untouched', () {
      expect(sourceTypeOf('ani:42'), ProviderType.anime);
      // The two prefixes must not be confused by a shared numeric suffix.
      expect(sourceTypeOf('ani:42'), isNot(sourceTypeOf('mihon:42')));
    });

  });

  // ── categorizedSources / filterBucketsForMode (integration: GetIt + Hive) ──
  group('categorizedSources + filterBucketsForMode', () {
    late Directory tempDir;
    late MihonManager mihonMgr;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('src_switch_mihon_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      sl.registerSingleton<AniyomiManager>(
        AniyomiManager()..register(AniyomiProvider(info: _aniInfo(id: 1))),
      );
      mihonMgr = MihonManager()
        ..register(MihonProvider(info: _mihonInfo(id: 42)));
      sl.registerSingleton<MihonManager>(mihonMgr);
    });

    tearDownAll(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('"mihon" without the colon is NOT treated as a Mihon source', () {
      // Guards the prefix itself: a JS provider literally named "mihonesque"
      // must keep falling through to the registry (→ anime by default), not
      // get silently retyped as manga. Needs the registry, hence this group.
      expect(sourceTypeOf('mihonesque'), ProviderType.anime);
    });

    test('a Mihon source lands in the manga bucket with its label + repo tag', () {
      final b = categorizedSources();
      final rows = b.manga.where((r) => r.id == 'mihon:42').toList();
      expect(rows, hasLength(1));
      expect(rows.single.label, 'Mihon · MangaDex');
      // The language rides in the repo/subtitle field. Multi-language
      // extensions (MANGA Plus and friends) are a SourceFactory yielding one
      // source per language, all sharing a display name — without this they
      // render as N identical rows that read as a duplicate install.
      expect(rows.single.repo, 'Mihon · en');
    });

    test('same-name sources from a multi-language extension are distinguishable',
        () {
      // The reported bug: installing MANGA Plus looked like five duplicate
      // installs. It is one SourceFactory yielding one source PER LANGUAGE —
      // distinct ids, identical display names. The rows must differ somewhere
      // a user can see, or they read as duplicates.
      mihonMgr
        ..register(MihonProvider(
            info: _mihonInfo(id: 501, name: 'MANGA Plus', lang: 'en')))
        ..register(MihonProvider(
            info: _mihonInfo(id: 502, name: 'MANGA Plus', lang: 'es')));

      final rows = categorizedSources()
          .manga
          .where((r) => r.label == 'Mihon · MANGA Plus')
          .toList();

      expect(rows, hasLength(2), reason: 'both language variants present');
      expect(
        rows.map((r) => r.repo).toSet(),
        {'Mihon · en', 'Mihon · es'},
        reason: 'identical labels must be told apart by the language subtitle',
      );
    });

    test('a Mihon source with no language falls back to the plain tag', () {
      mihonMgr.register(
          MihonProvider(info: _mihonInfo(id: 503, name: 'NoLang', lang: '')));
      final row = categorizedSources()
          .manga
          .firstWhere((r) => r.id == 'mihon:503');
      expect(row.repo, 'Mihon');
    });

    test('a Mihon source appears in NO anime/movies/nsfw/novel bucket', () {
      // The user constraint: anime mode's source list must not change.
      final b = categorizedSources();
      expect(b.anime.any((r) => r.id == 'mihon:42'), isFalse);
      expect(b.movies.any((r) => r.id == 'mihon:42'), isFalse);
      expect(b.nsfw.any((r) => r.id == 'mihon:42'), isFalse);
      expect(b.novel.any((r) => r.id == 'mihon:42'), isFalse);
    });

    test('the Aniyomi source is still in anime and NOT in manga', () {
      final b = categorizedSources();
      expect(b.anime.any((r) => r.id == 'ani:1'), isTrue);
      expect(b.manga.any((r) => r.id == 'ani:1'), isFalse);
    });

    test('manga mode keeps the Mihon row — _typeOfFromMap agrees with sourceTypeOf', () {
      // Without the mihon: branch in the precomputed-map twin, this row would
      // resolve to anime here and get filtered straight out of the bucket
      // categorizedSources just put it in.
      final b = filterBucketsForMode(categorizedSources(), ContentMode.manga);
      expect(b.manga.any((r) => r.id == 'mihon:42'), isTrue);
      expect(b.anime, isEmpty);
    });

    test('anime mode drops the Mihon row and keeps the Aniyomi one', () {
      final b = filterBucketsForMode(categorizedSources(), ContentMode.anime);
      expect(b.manga.any((r) => r.id == 'mihon:42'), isFalse);
      expect(b.anime.any((r) => r.id == 'ani:1'), isTrue);
    });

    test('anime mode buckets are byte-identical to the unfiltered ones', () {
      // The strongest form of "anime is unchanged": with a Mihon source
      // registered, anime mode's anime/movies/nsfw lists must be exactly what
      // categorizedSources produced.
      final raw = categorizedSources();
      final filtered = filterBucketsForMode(raw, ContentMode.anime);
      expect(filtered.anime, raw.anime);
      expect(filtered.movies, raw.movies);
      expect(filtered.nsfw, raw.nsfw);
    });

    test('hasReadingSourcesFor(manga) is true once a Mihon source exists', () {
      expect(hasReadingSourcesFor(ContentMode.manga), isTrue);
      expect(hasReadingSourcesFor(ContentMode.novel), isFalse);
      expect(hasReadingSourcesFor(ContentMode.anime), isFalse);
    });

    test('an NSFW Mihon source is hidden until the nsfwSources pref is on', () async {
      final prefs = sl<PlaybackPrefs>();
      mihonMgr.register(MihonProvider(info: _mihonInfo(id: 99, nsfw: true)));

      await prefs.setNsfwSources(false);
      expect(
        categorizedSources().manga.any((r) => r.id == 'mihon:99'),
        isFalse,
      );

      await prefs.setNsfwSources(true);
      expect(categorizedSources().manga.any((r) => r.id == 'mihon:99'), isTrue);

      await prefs.setNsfwSources(false);
      mihonMgr.removeWhere((p) => p.sourceId == 'mihon:99');
    });
  });

  // A GetIt with no MihonManager at all is the state every pre-M7 test runs
  // in — categorizedSources must not crash there.
  group('categorizedSources without a registered MihonManager', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('src_switch_nomihon');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();
      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      sl.registerSingleton<AniyomiManager>(
        AniyomiManager()..register(AniyomiProvider(info: _aniInfo(id: 1))),
      );
    });

    tearDownAll(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('does not throw, and anime still resolves', () {
      expect(sl.isRegistered<MihonManager>(), isFalse);
      final b = categorizedSources();
      expect(b.manga, isEmpty);
      expect(b.anime.any((r) => r.id == 'ani:1'), isTrue);
    });
  });
}
