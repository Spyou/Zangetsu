import 'package:hive/hive.dart';

import '../provider/cloudstream_provider.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';

/// Codec that backs up and restores provider repos, installed providers, and
/// per-source settings.
///
/// Restore is union-only — existing repos and providers are never removed,
/// only missing ones are added.
///
/// Inject the three dependencies so unit tests can supply fakes without any
/// Hive/network/platform involvement:
///   [_repos]   — JS provider repo registry
///   [_registry]— installed provider registry
///   [_cs]      — CloudStream manager (null on non-Android or in tests)
class SourcesBackup {
  const SourcesBackup(this._repos, this._registry, this._cs);

  final ProviderReposRegistry _repos;
  final ProviderRegistry _registry;

  /// Null on non-Android platforms or in tests that don't need CS restore.
  final CloudStreamManager? _cs;

  static const String _psBoxName = 'provider_settings';

  // The Hive key under which CloudStreamManager persists its repo list.
  // Matches the private `_reposKey` constant in CloudStreamManager.
  static const String _csReposKey = 'repos';

  // ── build ──────────────────────────────────────────────────────────────────

  /// Dumps current state into a serialisable [Map].
  ///
  /// Keys:
  /// - `jsRepoUrls` — list of JS provider repo manifest URLs.
  /// - `csRepoUrls` — list of CloudStream repo URLs (from the `cs_repos` box).
  /// - `providers`  — every installed provider entry serialised via `toJson`.
  /// - `settings`   — contents of the `provider_settings` Hive box, or `{}`.
  Map<String, dynamic> build() => {
        'jsRepoUrls': _repos.getAll().map((r) => r.url).toList(),
        'csRepoUrls': _readCsRepoUrls(),
        'providers': _registry.getAll().map((e) => e.toJson()).toList(),
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
