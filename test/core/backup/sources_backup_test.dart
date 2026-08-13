import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/backup/sources_backup.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart'
    show AniyomiManager;
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

/// A minimal [ProviderRepo] helper for tests.
ProviderRepo _repo(String url) => ProviderRepo(
      url: url,
      name: 'Test Repo',
      description: '',
      sources: const [],
      lastSyncedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

/// A minimal [ProviderRegistryEntry] helper for tests.
ProviderRegistryEntry _entry({
  required String sourceId,
  required String fileUrl,
  String repoUrl = 'https://repo.example.com/index.json',
}) => ProviderRegistryEntry(
      name: sourceId,
      url: fileUrl,
      version: '1.0.0',
      enabled: true,
      originRepoUrl: repoUrl,
      displayName: sourceId,
    );

/// Stub [ProviderReposRegistry]: tracks a mutable list of repos and records
/// [fetchAndCache] calls. Throws [ProviderRepoException] when [_throwUrls]
/// contains the url.
class _StubRepos implements ProviderReposRegistry {
  _StubRepos(List<ProviderRepo> initial, {Set<String>? throwUrls})
      : _repos = List<ProviderRepo>.from(initial),
        _throwUrls = throwUrls ?? {};

  final List<ProviderRepo> _repos;
  final Set<String> _throwUrls;
  final List<String> fetchedUrls = [];

  @override
  List<ProviderRepo> getAll() => List.unmodifiable(_repos);

  @override
  Future<ProviderRepo> fetchAndCache(String url, {String? customName}) async {
    fetchedUrls.add(url);
    if (_throwUrls.contains(url)) {
      throw ProviderRepoException('Simulated network error for $url');
    }
    final repo = _repo(url);
    _repos.add(repo);
    return repo;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Stub [ProviderRegistry]: tracks a mutable list of entries and records
/// [install] calls. Throws when [_throwSourceIds] contains the sourceId.
class _StubProviderRegistry implements ProviderRegistry {
  _StubProviderRegistry(List<ProviderRegistryEntry> initial,
      {Set<String>? throwSourceIds})
      : _entries = List<ProviderRegistryEntry>.from(initial),
        _throwSourceIds = throwSourceIds ?? {};

  final List<ProviderRegistryEntry> _entries;
  final Set<String> _throwSourceIds;
  final List<String> installedIds = [];

  @override
  List<ProviderRegistryEntry> getAll() => List.unmodifiable(_entries);

  @override
  ProviderRegistryEntry? entryFor(String sourceId) =>
      _entries.where((e) => e.name == sourceId).firstOrNull;

  @override
  Future<ProviderRegistryEntry> install({
    required String sourceId,
    required String fileUrl,
    String repoUrl = '',
    String displayName = '',
    String version = '1.0.0',
    bool force = false,
  }) async {
    installedIds.add(sourceId);
    if (_throwSourceIds.contains(sourceId)) {
      throw Exception('Simulated install failure for $sourceId');
    }
    final entry = _entry(sourceId: sourceId, fileUrl: fileUrl, repoUrl: repoUrl);
    _entries.add(entry);
    return entry;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sources_backup_test_');
    Hive.init(dir.path);
    await Hive.openBox<Map>('provider_settings');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  // ── (a) build collects current repos and providers ─────────────────────────

  test('build: collects jsRepoUrls from repos registry', () {
    final repos = _StubRepos([
      _repo('https://repo1.example.com/index.json'),
      _repo('https://repo2.example.com/index.json'),
    ]);
    final registry = _StubProviderRegistry([]);
    final backup = SourcesBackup(repos, registry, null);

    final data = backup.build();

    expect(data['jsRepoUrls'], containsAll([
      'https://repo1.example.com/index.json',
      'https://repo2.example.com/index.json',
    ]));
  });

  test('build: collects providers from registry as toJson maps', () {
    final repos = _StubRepos([]);
    final registry = _StubProviderRegistry([
      _entry(
          sourceId: 'allanime',
          fileUrl: 'https://cdn.example.com/allanime.js'),
    ]);
    final backup = SourcesBackup(repos, registry, null);

    final data = backup.build();

    final providers = data['providers'] as List;
    expect(providers.length, 1);
    final p = providers.first as Map;
    expect(p['name'], 'allanime');
    expect(p['url'], 'https://cdn.example.com/allanime.js');
  });

  test('build: includes provider_settings box contents in settings field',
      () async {
    final box = Hive.box<Map>('provider_settings');
    await box.put('repoUrl::src1', {'domain': 'alt.example.com'});

    final repos = _StubRepos([]);
    final registry = _StubProviderRegistry([]);
    final backup = SourcesBackup(repos, registry, null);

    final data = backup.build();

    final settings = data['settings'] as Map;
    expect(settings.containsKey('repoUrl::src1'), isTrue);
  });

  // ── (b) merge does NOT call fetchAndCache for already-present repos ─────────

  test('merge: skips fetchAndCache when repo url is already in getAll()',
      () async {
    const existingUrl = 'https://already-added.example.com/index.json';
    final repos = _StubRepos([_repo(existingUrl)]);
    final registry = _StubProviderRegistry([]);
    final backup = SourcesBackup(repos, registry, null);

    await backup.merge({'jsRepoUrls': [existingUrl], 'csRepoUrls': [], 'providers': [], 'settings': {}});

    expect(repos.fetchedUrls, isEmpty);
  });

  // ── (c) merge DOES call fetchAndCache once for a new repo url ──────────────

  test('merge: calls fetchAndCache once for a new repo url', () async {
    const newUrl = 'https://new-repo.example.com/index.json';
    final repos = _StubRepos([]);
    final registry = _StubProviderRegistry([]);
    final backup = SourcesBackup(repos, registry, null);

    final failures = await backup.merge({
      'jsRepoUrls': [newUrl],
      'csRepoUrls': [],
      'providers': [],
      'settings': {},
    });

    expect(repos.fetchedUrls, [newUrl]);
    expect(failures, isEmpty);
  });

  // ── (d) a provider install failure is recorded and does not abort ───────────

  test('merge: install failure is recorded in failures and does not abort remaining',
      () async {
    final repos = _StubRepos([]);
    final registry = _StubProviderRegistry(
      [],
      throwSourceIds: {'bad-provider'},
    );
    final backup = SourcesBackup(repos, registry, null);

    final providers = [
      _entry(sourceId: 'bad-provider',
          fileUrl: 'https://cdn.example.com/bad.js').toJson(),
      _entry(sourceId: 'good-provider',
          fileUrl: 'https://cdn.example.com/good.js').toJson(),
    ];

    final failures = await backup.merge({
      'jsRepoUrls': [],
      'csRepoUrls': [],
      'providers': providers,
      'settings': {},
    });

    // The failure is recorded.
    expect(failures.any((f) => f.contains('bad-provider')), isTrue);
    // The good provider was still installed.
    expect(registry.installedIds, contains('good-provider'));
    // Only one failure.
    expect(failures.length, 1);
  });

  // ── provider_settings round-trip ────────────────────────────────────────────

  test('merge: restores provider_settings via putAll (union)', () async {
    final box = Hive.box<Map>('provider_settings');
    // Pre-existing setting must survive.
    await box.put('repoUrl::existing', {'k': 'v'});

    final repos = _StubRepos([]);
    final registry = _StubProviderRegistry([]);
    final backup = SourcesBackup(repos, registry, null);

    await backup.merge({
      'jsRepoUrls': [],
      'csRepoUrls': [],
      'providers': [],
      'settings': {
        'repoUrl::new-src': {'domain': 'backup.example.com'},
      },
    });

    // Backed-up setting was added.
    expect(box.containsKey('repoUrl::new-src'), isTrue);
    // Pre-existing setting is still there.
    expect(box.containsKey('repoUrl::existing'), isTrue);
  });

  // ── _cs == null: CS repos are skipped without error ────────────────────────

  test('merge: cs repos are silently skipped when _cs is null', () async {
    final repos = _StubRepos([]);
    final registry = _StubProviderRegistry([]);
    final backup = SourcesBackup(repos, registry, null);

    final failures = await backup.merge({
      'jsRepoUrls': [],
      'csRepoUrls': ['https://cs.example.com/repo.json'],
      'providers': [],
      'settings': {},
    });

    expect(failures, isEmpty);
  });

  // ── already-installed provider is not re-installed ─────────────────────────

  test('merge: skips install for provider whose sourceId is already in registry',
      () async {
    final repos = _StubRepos([]);
    final registry = _StubProviderRegistry([
      _entry(sourceId: 'already-installed',
          fileUrl: 'https://cdn.example.com/alr.js'),
    ]);
    final backup = SourcesBackup(repos, registry, null);

    await backup.merge({
      'jsRepoUrls': [],
      'csRepoUrls': [],
      'providers': [
        _entry(sourceId: 'already-installed',
            fileUrl: 'https://cdn.example.com/alr.js').toJson(),
      ],
      'settings': {},
    });

    expect(registry.installedIds, isEmpty);
  });

  // ── Aniyomi: build reads the repo + installed boxes ─────────────────────────

  test('build: includes aniyomi repo urls and installed pkgs', () async {
    final repoBox = await Hive.openBox<String>('aniyomi_repos');
    await repoBox.add('https://raw.githubusercontent.com/o/r/main');
    final instBox = await Hive.openBox<dynamic>(
        AniyomiExtensionService.installedBoxName);
    await instBox.put('eu.kanade.ext.animeworld', '/data/apk/a.apk');

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null);
    final data = backup.build();

    expect(data['aniyomiRepoUrls'],
        ['https://raw.githubusercontent.com/o/r/main']);
    expect(data['aniyomiPkgs'], ['eu.kanade.ext.animeworld']);
  });

  // ── Aniyomi: merge unions repo urls into the box ────────────────────────────

  test('merge: adds missing aniyomi repo urls, skips existing', () async {
    final repoBox = await Hive.openBox<String>('aniyomi_repos');
    await repoBox.add('https://existing.example/main');

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null);
    await backup.merge({
      'aniyomiRepoUrls': [
        'https://existing.example/main',
        'https://new.example/main',
      ],
    });

    expect(repoBox.values.toList(),
        ['https://existing.example/main', 'https://new.example/main']);
  });

  // ── Aniyomi: merge reinstalls missing extensions from repo indexes ─────────

  test('merge: reinstalls missing aniyomi pkgs, records not-found failures',
      () async {
    await Hive.openBox<dynamic>(AniyomiExtensionService.installedBoxName);
    final ani = _StubAniyomiService();
    final entry = AniyomiRepoEntry(
      name: 'AnimeWorld',
      pkg: 'eu.kanade.ext.animeworld',
      apk: 'animeworld.apk',
      lang: 'it',
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: const [],
      repoBaseUrl: 'https://repo.example/main',
    );

    final backup = SourcesBackup(
      _StubRepos([]),
      _StubProviderRegistry([]),
      null,
      aniyomi: ani,
      fetchAniyomiIndex: (url) async => [entry],
    );

    final failures = await backup.merge({
      'aniyomiRepoUrls': ['https://repo.example/main'],
      'aniyomiPkgs': ['eu.kanade.ext.animeworld', 'eu.kanade.ext.ghost'],
    });

    // The known pkg was reinstalled; the unknown one is a recorded failure.
    expect(ani.installedPkgs, ['eu.kanade.ext.animeworld']);
    expect(failures, ['Aniyomi extension: eu.kanade.ext.ghost']);
  });

  test('merge: does not reinstall an already-installed aniyomi pkg', () async {
    final instBox = await Hive.openBox<dynamic>(
        AniyomiExtensionService.installedBoxName);
    await instBox.put('eu.kanade.ext.animeworld', '/data/apk/a.apk');
    final ani = _StubAniyomiService();

    final backup = SourcesBackup(
      _StubRepos([]),
      _StubProviderRegistry([]),
      null,
      aniyomi: ani,
      fetchAniyomiIndex: (url) async => [],
    );

    final failures = await backup.merge({
      'aniyomiPkgs': ['eu.kanade.ext.animeworld'],
    });

    expect(ani.installedPkgs, isEmpty);
    expect(failures, isEmpty);
  });

  // ── Mihon: build reads the repo + installed boxes ───────────────────────────

  test('build: includes mihon repo urls and installed pkgs', () async {
    final repoBox = await Hive.openBox<String>('mihon_repos');
    await repoBox.add('https://raw.githubusercontent.com/o/mihon-repo/main');
    final instBox =
        await Hive.openBox<dynamic>(MihonExtensionService.installedBoxName);
    await instBox.put('eu.kanade.ext.mangaworld', '/data/apk/m.apk');

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null);
    final data = backup.build();

    expect(data['mihonRepoUrls'],
        ['https://raw.githubusercontent.com/o/mihon-repo/main']);
    expect(data['mihonPkgs'], ['eu.kanade.ext.mangaworld']);
  });

  // ── Mihon: merge unions repo urls into the box ──────────────────────────────

  test('merge: adds missing mihon repo urls, skips existing', () async {
    final repoBox = await Hive.openBox<String>('mihon_repos');
    await repoBox.add('https://existing.example/mihon');

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null);
    await backup.merge({
      'mihonRepoUrls': [
        'https://existing.example/mihon',
        'https://new.example/mihon',
      ],
    });

    expect(repoBox.values.toList(),
        ['https://existing.example/mihon', 'https://new.example/mihon']);
  });

  // ── Mihon: merge reinstalls missing extensions from repo indexes ───────────

  test('merge: reinstalls missing mihon pkgs, records not-found failures',
      () async {
    await Hive.openBox<dynamic>(MihonExtensionService.installedBoxName);
    final mihon = _StubMihonService();
    final entry = AniyomiRepoEntry(
      name: 'MangaWorld',
      pkg: 'eu.kanade.ext.mangaworld',
      apk: 'mangaworld.apk',
      lang: 'en',
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: const [],
      repoBaseUrl: 'https://repo.example/mihon',
    );

    final backup = SourcesBackup(
      _StubRepos([]),
      _StubProviderRegistry([]),
      null,
      mihon: mihon,
      fetchMihonIndex: (url) async => [entry],
    );

    final failures = await backup.merge({
      'mihonRepoUrls': ['https://repo.example/mihon'],
      'mihonPkgs': ['eu.kanade.ext.mangaworld', 'eu.kanade.ext.ghost'],
    });

    expect(mihon.installedPkgs, ['eu.kanade.ext.mangaworld']);
    expect(failures, ['Mihon extension: eu.kanade.ext.ghost']);
  });

  test('merge: does not reinstall an already-installed mihon pkg', () async {
    final instBox =
        await Hive.openBox<dynamic>(MihonExtensionService.installedBoxName);
    await instBox.put('eu.kanade.ext.mangaworld', '/data/apk/m.apk');
    final mihon = _StubMihonService();

    final backup = SourcesBackup(
      _StubRepos([]),
      _StubProviderRegistry([]),
      null,
      mihon: mihon,
      fetchMihonIndex: (url) async => [],
    );

    final failures =
        await backup.merge({'mihonPkgs': ['eu.kanade.ext.mangaworld']});

    expect(mihon.installedPkgs, isEmpty);
    expect(failures, isEmpty);
  });

  // ── LNReader: build reads the repo + installed-plugin boxes ────────────────

  test('build: includes lnreader repo urls and installed pkgs', () async {
    final repoBox = await Hive.openBox<String>('lnreader_repos');
    await repoBox.add('https://repo.example/lnreader/index.json');
    final box = await Hive.openBox<Map>('lnreader_plugins');
    await box.put('novelsite', {'id': 'novelsite', 'name': 'Novel Site'});

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null);
    final data = backup.build();

    expect(data['lnreaderRepoUrls'],
        ['https://repo.example/lnreader/index.json']);
    expect(data['lnreaderPkgs'], ['novelsite']);
  });

  // ── LNReader: merge unions repo urls into the box ───────────────────────────

  test('merge: adds missing lnreader repo urls, skips existing', () async {
    final repoBox = await Hive.openBox<String>('lnreader_repos');
    await repoBox.add('https://existing.example/lnreader');

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null);
    await backup.merge({
      'lnreaderRepoUrls': [
        'https://existing.example/lnreader',
        'https://new.example/lnreader',
      ],
    });

    expect(repoBox.values.toList(),
        ['https://existing.example/lnreader', 'https://new.example/lnreader']);
  });

  // ── LNReader: merge installs a missing plugin from a tracked repo's index ──

  test(
      'merge: installs a missing lnreader plugin from a tracked repo, '
      'records not-found failures', () async {
    await Hive.openBox<Map>('lnreader_plugins');
    final lnr = LnReaderExtensionService(httpGet: (url) async {
      if (url == 'https://repo.example/lnreader/index.json') {
        return jsonEncode([
          {
            'id': 'novelsite',
            'name': 'Novel Site',
            'site': 'https://novelsite.example',
            'lang': 'English',
            'version': '1.0.0',
            'url': 'https://novelsite.example/plugin.js',
            'iconUrl': '',
          },
        ]);
      }
      return 'js-source-code';
    });

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null,
        lnreader: lnr);

    final failures = await backup.merge({
      'lnreaderRepoUrls': ['https://repo.example/lnreader/index.json'],
      'lnreaderPkgs': ['novelsite', 'ghost'],
    });

    expect(failures, ['Novel source: ghost']);
    expect(lnr.installed().map((m) => m.id), contains('novelsite'));
    expect(lnr.jsFor('novelsite'), 'js-source-code');
  });

  test('merge: does not reinstall an already-installed lnreader plugin',
      () async {
    final box = await Hive.openBox<Map>('lnreader_plugins');
    await box.put('novelsite', {
      'id': 'novelsite',
      'name': 'Novel Site',
      'site': '',
      'lang': '',
      'version': '',
      'url': '',
      'iconUrl': '',
      'js': 'already-here',
    });
    var fetchedIndex = false;
    final lnr = LnReaderExtensionService(httpGet: (url) async {
      fetchedIndex = true;
      return jsonEncode([]);
    });

    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null,
        lnreader: lnr);

    final failures = await backup.merge({'lnreaderPkgs': ['novelsite']});

    expect(failures, isEmpty);
    expect(fetchedIndex, isFalse); // already installed — no network call
  });

  // ── back-compat: an OLD backup with no manga/novel keys still imports ──────

  test('merge: an OLD-shaped payload (no mihon/lnreader keys) imports fine',
      () async {
    final backup = SourcesBackup(_StubRepos([]), _StubProviderRegistry([]), null,
        aniyomi: _StubAniyomiService(),
        mihon: _StubMihonService(),
        lnreader: LnReaderExtensionService(httpGet: (_) async => '[]'));

    // Shape of a backup taken before manga/novel support existed — no
    // aniyomiRepoUrls/aniyomiPkgs/mihonRepoUrls/mihonPkgs/lnreaderPkgs keys.
    final failures = await backup.merge({
      'jsRepoUrls': [],
      'csRepoUrls': [],
      'providers': [],
      'settings': {},
    });

    expect(failures, isEmpty);
  });
}

/// Stub [AniyomiExtensionService]: records installFromRepo calls and pretends
/// each install produced one provider (success).
class _StubAniyomiService implements AniyomiExtensionService {
  final List<String> installedPkgs = [];

  @override
  Future<List<AniyomiProvider>> installFromRepo(
    AniyomiRepoEntry entry, {
    Dio? dio,
    Directory? apkDirectory,
    Future<void> Function(String url, String savePath)? downloader,
    AniyomiManager? manager,
  }) async {
    installedPkgs.add(entry.pkg);
    // Non-empty result = success; the codec only checks isEmpty.
    return [
      AniyomiProvider(
        info: const AniyomiSourceInfo(
          id: 1,
          name: 'AnimeWorld',
          lang: 'it',
          baseUrl: 'https://animeworld.example',
          pkg: 'eu.kanade.ext.animeworld',
          nsfw: false,
        ),
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Stub [MihonExtensionService]: the manga twin of [_StubAniyomiService].
class _StubMihonService implements MihonExtensionService {
  final List<String> installedPkgs = [];

  @override
  Future<List<MihonProvider>> installFromRepo(
    AniyomiRepoEntry entry, {
    Dio? dio,
    Directory? apkDirectory,
    Future<void> Function(String url, String savePath)? downloader,
    MihonManager? manager,
  }) async {
    installedPkgs.add(entry.pkg);
    // Non-empty result = success; the codec only checks isEmpty.
    return [
      MihonProvider(
        info: const MihonSourceInfo(
          id: 1,
          name: 'MangaWorld',
          lang: 'en',
          baseUrl: 'https://mangaworld.example',
          pkg: 'eu.kanade.ext.mangaworld',
          nsfw: false,
        ),
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
