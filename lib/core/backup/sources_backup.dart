import 'package:hive/hive.dart';

import '../aniyomi/aniyomi_extension_service.dart';
import '../aniyomi/aniyomi_repo.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';

/// Codec that backs up and restores provider repos, installed providers, and
/// per-source settings.
///
/// Restore is union-only — existing repos and providers are never removed,
/// only missing ones are added.
///
/// Inject the dependencies so unit tests can supply fakes without any
/// Hive/network/platform involvement:
///   [_repos]   — JS provider repo registry
///   [_registry]— installed provider registry
///   [_cs]      — CloudStream manager (null on non-Android or in tests)
///   [_ani]     — Aniyomi extension service (null on non-Android or in tests)
///   [_fetchAniyomiIndex] — Aniyomi repo index fetcher (overridable in tests)
class SourcesBackup {
  const SourcesBackup(
    this._repos,
    this._registry,
    this._cs, {
    AniyomiExtensionService? aniyomi,
    Future<List<AniyomiRepoEntry>> Function(String repoBaseUrl)?
        fetchAniyomiIndex,
  })  : _ani = aniyomi,
        _fetchAniyomiIndex = fetchAniyomiIndex ?? AniyomiRepo.fetchIndex;

  final ProviderReposRegistry _repos;
  final ProviderRegistry _registry;

  /// Null on non-Android platforms or in tests that don't need CS restore.
  final CloudStreamManager? _cs;

  /// Null on non-Android platforms or in tests that don't need Aniyomi restore.
  final AniyomiExtensionService? _ani;

  final Future<List<AniyomiRepoEntry>> Function(String repoBaseUrl)
      _fetchAniyomiIndex;

  static const String _psBoxName = 'provider_settings';

  // The Hive key under which CloudStreamManager persists its repo list.
  // Matches the private `_reposKey` constant in CloudStreamManager.
  static const String _csReposKey = 'repos';

  // The Hive box of tracked Aniyomi repo base URLs (Box<String>, list-style).
  // Matches `kAniyomiReposBoxName` in the sources UI.
  static const String _aniReposBoxName = 'aniyomi_repos';

  // ── build ──────────────────────────────────────────────────────────────────

  /// Dumps current state into a serialisable [Map].
  ///
  /// Keys:
  /// - `jsRepoUrls` — list of JS provider repo manifest URLs.
  /// - `csRepoUrls` — list of CloudStream repo URLs (from the `cs_repos` box).
  /// - `csPlugins`  — installed CloudStream plugins as `{internalName, repoUrl}`.
  /// - `providers`  — every installed provider entry serialised via `toJson`.
  /// - `aniyomiRepoUrls` — tracked Aniyomi repo base URLs.
  /// - `aniyomiPkgs` — installed Aniyomi extension package names.
  /// - `settings`   — contents of the `provider_settings` Hive box, or `{}`.
  Map<String, dynamic> build() => {
        'jsRepoUrls': _repos.getAll().map((r) => r.url).toList(),
        'csRepoUrls': _readCsRepoUrls(),
        'csPlugins': _installedCsPlugins(),
        'providers': _registry.getAll().map((e) => e.toJson()).toList(),
        'aniyomiRepoUrls': _readAniyomiRepoUrls(),
        'aniyomiPkgs': _readAniyomiPkgs(),
        'settings': _readProviderSettings(),
      };

  // ── merge ──────────────────────────────────────────────────────────────────

  /// Restores from [data] using union semantics — never removes anything.
  ///
  /// Each item is wrapped in an independent try/catch so one broken entry
  /// does not abort the rest. Returns a list of human-readable failure
  /// strings (empty on full success).
  Future<List<String>> merge(Map<String, dynamic> data) async {
    final failures = <String>[];

    // JS provider repos -------------------------------------------------------
    final jsRepoUrls =
        (data['jsRepoUrls'] as List?)?.cast<String>() ?? const <String>[];
    final existingJsUrls = _repos.getAll().map((r) => r.url).toSet();
    for (final url in jsRepoUrls) {
      if (existingJsUrls.contains(url)) continue; // already present — skip
      try {
        await _repos.fetchAndCache(url);
      } catch (_) {
        failures.add('Provider repo: $url');
      }
    }

    // CloudStream repos -------------------------------------------------------
    final csRepoUrls =
        (data['csRepoUrls'] as List?)?.cast<String>() ?? const <String>[];
    for (final url in csRepoUrls) {
      if (_cs == null) continue; // non-Android or test with null _cs — skip
      if (_cs.hasRepo(url)) continue; // already added — skip
      try {
        await _cs.addRepo(url);
      } catch (_) {
        failures.add('CloudStream repo: $url');
      }
    }

    // CloudStream plugins (after repos, so the catalogs exist) ----------------
    final csPlugins = (data['csPlugins'] as List?) ?? const [];
    for (final raw in csPlugins) {
      if (_cs == null) break;
      if (raw is! Map) continue;
      final internalName = (raw['internalName'] ?? '').toString();
      final repoUrl = (raw['repoUrl'] ?? '').toString();
      if (internalName.isEmpty) continue;
      if (_cs.isPluginInstalled(internalName,
          repoUrl: repoUrl.isEmpty ? null : repoUrl)) {
        continue; // already installed — skip
      }
      try {
        // Find the plugin's meta in its repo's catalog, then install it.
        final group = _cs.repoGroups.firstWhere((g) => g.url == repoUrl);
        final meta =
            group.catalog.firstWhere((m) => m.internalName == internalName);
        await _cs.installPlugin(meta, repoUrl: repoUrl);
      } catch (_) {
        failures.add('CloudStream plugin: $internalName');
      }
    }

    // Aniyomi repos (union into the Box<String> list) --------------------------
    final aniRepoUrls =
        (data['aniyomiRepoUrls'] as List?)?.cast<String>() ?? const <String>[];
    if (aniRepoUrls.isNotEmpty) {
      try {
        final box = Hive.isBoxOpen(_aniReposBoxName)
            ? Hive.box<String>(_aniReposBoxName)
            : await Hive.openBox<String>(_aniReposBoxName);
        for (final url in aniRepoUrls) {
          if (box.values.contains(url)) continue;
          await box.add(url);
        }
      } catch (_) {
        failures.add('Aniyomi repos');
      }
    }

    // Aniyomi extensions (re-download from any tracked repo's index) -----------
    final aniPkgs =
        (data['aniyomiPkgs'] as List?)?.cast<String>() ?? const <String>[];
    if (aniPkgs.isNotEmpty && _ani != null) {
      // installFromRepo persists pkg → apk path only when this box is open.
      if (!Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        try {
          await Hive.openBox<dynamic>(AniyomiExtensionService.installedBoxName);
        } catch (_) {}
      }
      final installedPkgs = _readAniyomiPkgs().toSet();
      final missing =
          aniPkgs.where((p) => !installedPkgs.contains(p)).toList();
      if (missing.isNotEmpty) {
        // Fetch each tracked repo's index once, then look pkgs up locally.
        final repoUrls = <String>{
          ...aniRepoUrls,
          if (Hive.isBoxOpen(_aniReposBoxName))
            ...Hive.box<String>(_aniReposBoxName).values,
        };
        final entriesByPkg = <String, AniyomiRepoEntry>{};
        for (final url in repoUrls) {
          try {
            for (final e in await _fetchAniyomiIndex(url)) {
              entriesByPkg.putIfAbsent(e.pkg, () => e);
            }
          } catch (_) {} // fetchIndex never throws, but stay defensive
        }
        for (final pkg in missing) {
          final entry = entriesByPkg[pkg];
          if (entry == null) {
            failures.add('Aniyomi extension: $pkg');
            continue;
          }
          // installFromRepo never throws — [] means the install failed.
          final providers = await _ani.installFromRepo(entry);
          if (providers.isEmpty) failures.add('Aniyomi extension: ${entry.name}');
        }
      }
    }

    // Installed providers (union: only add those not already present) ---------
    final providers = (data['providers'] as List?) ?? const [];
    for (final raw in providers) {
      if (raw is! Map) continue;
      final j = Map<String, dynamic>.from(raw);
      final sourceId = (j['name'] as String?) ?? '';
      if (sourceId.isEmpty) continue;
      if (_registry.entryFor(sourceId) != null) continue; // already installed
      try {
        await _registry.install(
          sourceId: sourceId,
          fileUrl: (j['url'] as String?) ?? '',
          repoUrl: (j['originRepoUrl'] as String?) ?? '',
          displayName: (j['displayName'] as String?) ?? '',
          version: (j['version'] as String?) ?? '1.0.0',
        );
      } catch (_) {
        failures.add('Provider: $sourceId');
      }
    }

    // Per-source settings (putAll = union, never clears existing rows) --------
    if (Hive.isBoxOpen(_psBoxName)) {
      final settings = data['settings'];
      if (settings is Map) {
        final toWrite = <String, Map<String, dynamic>>{};
        for (final e in settings.entries) {
          if (e.value is Map) {
            toWrite[e.key.toString()] =
                Map<String, dynamic>.from(e.value as Map);
          }
        }
        if (toWrite.isNotEmpty) {
          await Hive.box<Map>(_psBoxName).putAll(toWrite);
        }
      }
    }

    return failures;
  }

  // ── private helpers ────────────────────────────────────────────────────────

  /// Reads CloudStream repo URLs directly from the persisted `cs_repos` box.
  ///
  /// CloudStreamManager stores its `_repos` list under the `'repos'` key as a
  /// `List<Map>`, each map containing a `'url'` entry. Reading the box directly
  /// (rather than going through the manager) keeps the backup codec independent
  /// of Android platform availability.
  List<String> _readCsRepoUrls() {
    if (!Hive.isBoxOpen(CloudStreamManager.boxName)) return const [];
    final raw = Hive.box(CloudStreamManager.boxName).get(_csReposKey);
    if (raw is! List) return const [];
    return [
      for (final r in raw)
        if (r is Map) (r['url'] ?? '').toString(),
    ].where((u) => u.isNotEmpty).toList();
  }

  /// Every installed CloudStream plugin as `{internalName, repoUrl}`, resolved
  /// by checking each repo catalog entry against the live install state.
  List<Map<String, String>> _installedCsPlugins() {
    final cs = _cs;
    if (cs == null) return const [];
    return [
      for (final g in cs.repoGroups)
        for (final m in g.catalog)
          if (cs.isPluginInstalled(m.internalName, repoUrl: g.url))
            {'internalName': m.internalName, 'repoUrl': g.url},
    ];
  }

  /// Tracked Aniyomi repo base URLs (empty when the box isn't open).
  List<String> _readAniyomiRepoUrls() => Hive.isBoxOpen(_aniReposBoxName)
      ? Hive.box<String>(_aniReposBoxName).values.toList()
      : const [];

  /// Installed Aniyomi extension package names (empty when the box isn't open).
  List<String> _readAniyomiPkgs() =>
      Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)
          ? Hive.box<dynamic>(AniyomiExtensionService.installedBoxName)
              .keys
              .map((k) => k.toString())
              .toList()
          : const [];

  /// Reads the `provider_settings` Hive box as `{compositeKey: settingsMap}`.
  Map<String, dynamic> _readProviderSettings() {
    if (!Hive.isBoxOpen(_psBoxName)) return const {};
    final box = Hive.box<Map>(_psBoxName);
    return {
      for (final k in box.keys)
        k.toString(): Map<String, dynamic>.from(box.get(k) ?? const {}),
    };
  }
}
