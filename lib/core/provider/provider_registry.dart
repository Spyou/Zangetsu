import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../error/exceptions.dart';
import 'provider_downloader.dart';
import 'provider_manager.dart';
import 'provider_repo_registry.dart';

/// Separator inside a composite provider key (`'$repoUrl::$sourceId'`).
const String kProviderKeySep = '::';

/// Synthetic origin used for built-in / bundled providers that don't
/// come from a tracked repo. Keeps the composite key non-empty so
/// lookups behave consistently.
const String kBundledRepoUrl = 'bundled://';

/// True if [candidate] is a newer version than [current] (numeric, dot-split
/// semver; non-numeric segments count as 0). Used to flag source updates when
/// a repo manifest advertises a higher version than the installed entry.
bool isProviderVersionNewer(String candidate, String current) {
  List<int> parse(String v) => v
      .trim()
      .split(RegExp(r'[.+\-]'))
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final a = parse(candidate), b = parse(current);
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// One installed provider record. The composite key under which this is
/// stored is `providerKey(originRepoUrl, name)`.
class ProviderRegistryEntry {
  ProviderRegistryEntry({
    required this.name,
    required this.url,
    this.version = '1.0.0',
    this.enabled = true,
    this.originRepoUrl = '',
    this.displayName = '',
  });

  /// The sourceId — used to key the runtime slot (`__providers[name]`).
  final String name;

  /// `.js` download URL for repo providers, or `'bundled://<name>'` for
  /// providers shipped in the app's assets.
  final String url;
  final String version;
  final bool enabled;

  /// The repo manifest URL the provider originally came from, or
  /// [kBundledRepoUrl] for app-shipped providers.
  final String originRepoUrl;

  /// Display name snapshotted at install time so the source picker can
  /// label rows without re-resolving the repo manifest.
  final String displayName;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'version': version,
    'enabled': enabled,
    if (originRepoUrl.isNotEmpty) 'originRepoUrl': originRepoUrl,
    if (displayName.isNotEmpty) 'displayName': displayName,
  };

  factory ProviderRegistryEntry.fromJson(Map<String, dynamic> j) =>
      ProviderRegistryEntry(
        name: j['name'] as String,
        url: j['url'] as String,
        version: j['version'] as String? ?? '1.0.0',
        enabled: j['enabled'] as bool? ?? true,
        originRepoUrl: (j['originRepoUrl'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? '',
      );

  ProviderRegistryEntry copyWith({
    bool? enabled,
    String? version,
    String? url,
    String? originRepoUrl,
    String? displayName,
  }) => ProviderRegistryEntry(
    name: name,
    url: url ?? this.url,
    version: version ?? this.version,
    enabled: enabled ?? this.enabled,
    originRepoUrl: originRepoUrl ?? this.originRepoUrl,
    displayName: displayName ?? this.displayName,
  );

  bool get isBundled => url.startsWith(kBundledRepoUrl);
}

/// Composite-key registry of every installed provider. Tracks each
/// `(repoUrl, sourceId)` pair in Hive and mirrors enabled entries into
/// the shared QuickJS runtime via [ProviderRuntimeLoader].
///
/// Runtime constraint: the host has ONE slot per sourceId
/// (`__providers[sourceId]`), so two entries sharing a sourceId can't be
/// live simultaneously — the last one loaded wins.
class ProviderRegistry {
  static const String boxName = 'provider_registry';

  ProviderRegistry({
    required ProviderJsFetcher downloader,
    required ProviderRuntimeLoader manager,
    ProviderReposRegistry? repos,
  }) : _downloader = downloader,
       _manager = manager,
       _repos = repos;

  final ProviderJsFetcher _downloader;
  final ProviderRuntimeLoader _manager;
  // Used to resolve a source's manifest flags (e.g. NSFW) by repo + id.
  final ProviderReposRegistry? _repos;

  /// In-memory sourceId → jsSource for bundled providers. Populated at
  /// seed time (the injector loads these strings from rootBundle) so
  /// [loadAll] / [setEnabled] can re-load a bundled entry without
  /// guessing its asset path — critical because the 4 NetMirror sources
  /// all share ONE `providers/netmirror.js` asset.
  final Map<String, String> _bundledJs = {};

  Box<Map> get _box => Hive.box<Map>(boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  /// Composite key shape: `'$repoUrl::$sourceId'`.
  static String providerKey(String repoUrl, String sourceId) =>
      '$repoUrl$kProviderKeySep$sourceId';

  /// Returns the sourceId portion of [key]. Bare ids (no separator) are
  /// returned as-is.
  static String sourceIdOf(String key) {
    final i = key.lastIndexOf(kProviderKeySep);
    if (i < 0) return key;
    return key.substring(i + kProviderKeySep.length);
  }

  /// Returns the repoUrl portion of [key]. Bare ids → empty string.
  static String repoUrlOf(String key) {
    final i = key.lastIndexOf(kProviderKeySep);
    if (i < 0) return '';
    return key.substring(0, i);
  }

  /// All installed entries, sorted by composite key for stable ordering.
  List<ProviderRegistryEntry> getAll() {
    final keys = _box.keys.map((k) => k.toString()).toList()..sort();
    final out = <ProviderRegistryEntry>[];
    for (final k in keys) {
      final raw = _box.get(k);
      if (raw == null) continue;
      try {
        out.add(ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(raw)));
      } catch (e) {
        debugPrint('[ProviderRegistry] skip corrupt entry $k: $e');
      }
    }
    return out;
  }

  /// First installed entry whose sourceId == [sourceId], or null.
  ProviderRegistryEntry? entryFor(String sourceId) {
    for (final raw in _box.keys) {
      final k = raw.toString();
      if (sourceIdOf(k) != sourceId) continue;
      final v = _box.get(raw);
      if (v == null) continue;
      try {
        return ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(v));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Source ids advertised as NSFW by any cached repo manifest. Used to gate
  /// adult sources behind the Privacy toggle.
  Set<String> nsfwSourceIds() {
    final repos = _repos;
    if (repos == null) return const <String>{};
    final out = <String>{};
    for (final repo in repos.getAll()) {
      for (final s in repo.sources) {
        if (s.nsfw) out.add(s.id);
      }
    }
    return out;
  }

  Stream<BoxEvent> watch() => _box.watch();

  /// Installs (or refreshes) a bundled provider straight from in-memory
  /// [jsSource]. Writes an enabled `bundled://` entry, caches the source
  /// for later reloads, and loads it into the runtime immediately.
  Future<ProviderRegistryEntry> installFromBundled({
    required String name,
    required String jsSource,
    String displayName = 'Bundled',
  }) async {
    _bundledJs[name] = jsSource;
    final key = providerKey(kBundledRepoUrl, name);
    final existing = _box.get(key);
    // Preserve a user's enabled toggle across re-seeds; default enabled.
    final enabled = existing == null
        ? true
        : (ProviderRegistryEntry.fromJson(
            Map<String, dynamic>.from(existing),
          ).enabled);
    final entry = ProviderRegistryEntry(
      name: name,
      url: '$kBundledRepoUrl$name',
      enabled: enabled,
      originRepoUrl: kBundledRepoUrl,
      displayName: displayName,
    );
    await _box.put(key, entry.toJson());
    if (enabled) {
      _manager.load(
        sourceId: name,
        jsSource: jsSource,
        originRepoUrl: kBundledRepoUrl,
        displayName: displayName,
      );
    }
    return entry;
  }

  /// Installs a repo-hosted provider. Composite key is `(repoUrl, name)`
  /// so two repos publishing the same sourceId coexist. Downloads the
  /// `.js` and loads it into the runtime.
  Future<ProviderRegistryEntry> install({
    required String sourceId,
    required String fileUrl,
    String repoUrl = '',
    String displayName = '',
    String version = '1.0.0',
    bool force = false,
  }) async {
    final resolvedRepo = repoUrl.isEmpty ? kBundledRepoUrl : repoUrl;
    final entry = ProviderRegistryEntry(
      name: sourceId,
      url: fileUrl,
      version: version,
      originRepoUrl: resolvedRepo,
      displayName: displayName,
    );
    await _box.put(providerKey(resolvedRepo, sourceId), entry.toJson());
    // [force] bypasses the JS cache (and busts the CDN edge) so an Update
    // actually pulls the new code; a fresh install has nothing cached anyway.
    await _loadEntryIntoRuntime(entry, force: force);
    return entry;
  }

  /// Migration: drop every legacy `bundled://` entry. The app no longer ships
  /// built-in providers (all sources come from repos), so any bundled entries
  /// left over from older installs would fail to load (their JS isn't seeded).
  /// Safe to call every launch — a no-op once nothing bundled remains.
  Future<void> purgeBundled() async {
    final keys = _box.keys
        .map((k) => k.toString())
        .where((k) => repoUrlOf(k) == kBundledRepoUrl || !k.contains(kProviderKeySep))
        .toList();
    for (final k in keys) {
      final sourceId = sourceIdOf(k);
      _manager.remove(sourceId);
      _bundledJs.remove(sourceId);
      await _box.delete(k);
    }
  }

  /// Removes the entry at composite [key] and drops it from the runtime
  /// when no OTHER installed entry shares its sourceId.
  Future<void> uninstall(String key) async {
    if (!_box.containsKey(key)) return;
    final sourceId = sourceIdOf(key);
    final remaining = getAll()
        .where(
          (e) =>
              e.name == sourceId && providerKey(e.originRepoUrl, e.name) != key,
        )
        .toList();
    if (remaining.isEmpty) {
      _manager.remove(sourceId);
      _bundledJs.remove(sourceId);
      await _downloader.remove(sourceId);
    }
    await _box.delete(key);
  }

  /// Flips the enabled flag at composite [key], loading into / dropping
  /// from the runtime to match.
  Future<void> setEnabled(String key, bool enabled) async {
    final cur = _box.get(key);
    if (cur == null) return;
    final entry = ProviderRegistryEntry.fromJson(
      Map<String, dynamic>.from(cur),
    ).copyWith(enabled: enabled);
    await _box.put(key, entry.toJson());
    if (enabled) {
      await _loadEntryIntoRuntime(entry);
    } else {
      _manager.remove(entry.name);
    }
  }

  /// Loads every enabled installed entry into the runtime. Best-effort:
  /// per-entry failures are logged, not thrown, so one broken provider
  /// doesn't sink the app.
  Future<List<String>> loadAll({bool force = false}) async {
    final loaded = <String>[];
    for (final entry in getAll()) {
      if (!entry.enabled) continue;
      try {
        await _loadEntryIntoRuntime(entry, force: force);
        loaded.add(providerKey(entry.originRepoUrl, entry.name));
      } catch (e) {
        debugPrint('[ProviderRegistry] failed to load ${entry.name}: $e');
      }
    }
    return loaded;
  }

  Future<void> _loadEntryIntoRuntime(
    ProviderRegistryEntry entry, {
    bool force = false,
  }) async {
    if (entry.isBundled) {
      final js = _bundledJs[entry.name];
      if (js == null) {
        throw ProviderException(
          'Bundled provider ${entry.name} has no cached JS source '
          '(seed it via installFromBundled before loadAll)',
        );
      }
      _manager.load(
        sourceId: entry.name,
        jsSource: js,
        originRepoUrl: entry.originRepoUrl,
        displayName: entry.displayName,
      );
      return;
    }
    final cached = await _downloader.fetch(
      name: entry.name,
      url: entry.url,
      force: force,
    );
    _manager.load(
      sourceId: entry.name,
      jsSource: cached.jsCode,
      originRepoUrl: entry.originRepoUrl,
      displayName: entry.displayName,
    );
  }
}
