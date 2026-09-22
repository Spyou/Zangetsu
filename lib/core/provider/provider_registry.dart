import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:watch_app/core/hive/safe_box.dart';
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
    this.logoUrl = '',
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

  /// Absolute logo URL, snapshotted at install time for the same reason as
  /// [displayName] — the picker must not re-read a repo manifest per row.
  ///
  /// Empty when the manifest declares no `logo`, which is every Zangetsu source
  /// today: the field has existed on [RepoSource] all along and simply had no
  /// caller, so the app had no way to show an icon for its own sources while
  /// Aniyomi, Mihon and CloudStream all did. Empty keeps the letter tile.
  final String logoUrl;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'version': version,
    'enabled': enabled,
    if (originRepoUrl.isNotEmpty) 'originRepoUrl': originRepoUrl,
    if (displayName.isNotEmpty) 'displayName': displayName,
    if (logoUrl.isNotEmpty) 'logoUrl': logoUrl,
  };

  factory ProviderRegistryEntry.fromJson(Map<String, dynamic> j) =>
      ProviderRegistryEntry(
        name: j['name'] as String,
        url: j['url'] as String,
        version: j['version'] as String? ?? '1.0.0',
        enabled: j['enabled'] as bool? ?? true,
        originRepoUrl: (j['originRepoUrl'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? '',
        logoUrl: (j['logoUrl'] as String?) ?? '',
      );

  ProviderRegistryEntry copyWith({
    bool? enabled,
    String? version,
    String? url,
    String? originRepoUrl,
    String? displayName,
    String? logoUrl,
  }) => ProviderRegistryEntry(
    name: name,
    url: url ?? this.url,
    version: version ?? this.version,
    enabled: enabled ?? this.enabled,
    originRepoUrl: originRepoUrl ?? this.originRepoUrl,
    displayName: displayName ?? this.displayName,
    logoUrl: logoUrl ?? this.logoUrl,
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

  /// Bumped on every write to the registry box.
  ///
  /// Exists so [SourceRepository.pickableSources] can cache its answer and
  /// know when to throw it away. That getter reads EVERY entry here and JSON-
  /// parses it, and the source matcher calls it once per candidate lookup — a
  /// single Cloudflare "solve" reloaded home and ran it twelve times in thirty
  /// milliseconds, on the UI thread, with 214 sources installed.
  ///
  /// Driven by Hive's own change stream rather than by bumping a counter in
  /// each of the five mutating methods: a missed bump would leave a source
  /// invisible until restart, and that is a far worse bug than the one this
  /// is fixing.
  int get revision {
    _watch ??= _box.watch().listen((_) => _revision++);
    return _revision;
  }

  int _revision = 0;
  StreamSubscription<BoxEvent>? _watch;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
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

  /// Manifest content type for [sourceId] (`'anime'` / `'movie'`), or null when
  /// no cached manifest declares it. Used to group the source picker.
  String? typeOf(String sourceId) {
    final repos = _repos;
    if (repos == null) return null;
    for (final repo in repos.getAll()) {
      for (final s in repo.sources) {
        if (s.id == sourceId) return s.type;
      }
    }
    return null;
  }

  /// Every cached manifest's id -> type, built with a single walk over
  /// [ProviderReposRegistry.getAll] instead of one walk per id. Same
  /// first-match-wins semantics as calling [typeOf] per id — for callers
  /// resolving many ids at once (the source picker's mode filter, the
  /// picker's own bucketing) so the repo-manifest deserialize happens once
  /// per operation rather than once per row.
  Map<String, String> typeMapOf() {
    final repos = _repos;
    if (repos == null) return const <String, String>{};
    final out = <String, String>{};
    for (final repo in repos.getAll()) {
      for (final s in repo.sources) {
        out.putIfAbsent(s.id, () => s.type);
      }
    }
    return out;
  }

  /// [typeMapOf] and the logo map in ONE pass over the manifests.
  ///
  /// The row builder needs both, and a manifest pass is the expensive part —
  /// `source_switcher_perf_test` pins the number of `getAll()` calls per
  /// categorizedSources() run precisely so a second map cannot quietly double
  /// it. Callers that need only types still use [typeMapOf].
  ///
  /// Logos come from the LIVE manifest, not [ProviderRegistryEntry.logoUrl]:
  /// that snapshot is written only at install, so a provider installed before
  /// the field existed would keep its letter tile forever. The index is
  /// already fetched for browsing and update checks, so this backfills
  /// everything on the device for free — the same way `SourceIconStore` has
  /// always worked for Aniyomi and Mihon, without touching either.
  ({Map<String, String> types, Map<String, String> logos}) manifestMapsOf() {
    final repos = _repos;
    if (repos == null) {
      return (types: const <String, String>{}, logos: const <String, String>{});
    }
    final types = <String, String>{};
    final logos = <String, String>{};
    for (final repo in repos.getAll()) {
      for (final s in repo.sources) {
        types.putIfAbsent(s.id, () => s.type);
        final url = ProviderReposRegistry.resolveLogoUrl(repo, s);
        if (url != null && url.isNotEmpty) logos.putIfAbsent(s.id, () => url);
      }
    }
    return (types: types, logos: logos);
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
      await _manager.load(
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
    String logoUrl = '',
    bool force = false,
  }) async {
    final resolvedRepo = repoUrl.isEmpty ? kBundledRepoUrl : repoUrl;
    final entry = ProviderRegistryEntry(
      name: sourceId,
      url: fileUrl,
      version: version,
      originRepoUrl: resolvedRepo,
      displayName: displayName,
      logoUrl: logoUrl,
    );
    await _box.put(providerKey(resolvedRepo, sourceId), entry.toJson());
    // Logged because installing was previously silent: a shared log showed the
    // source count jump from 0 to 58 with nothing to explain it, which reads
    // like a boot bug rather than someone restoring a backup. A restore comes
    // through here too, one line per provider.
    debugPrint(
      '[ProviderRegistry] installed $sourceId v$version from $resolvedRepo',
    );
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
  Future<List<String>> loadAll({bool force = false, Duration? perEntryTimeout}) async {
    final allEntries = getAll();
    final enabledEntries = allEntries.where((e) => e.enabled).toList();
    debugPrint(
      '[ProviderRegistry] loadAll start · '
      '${allEntries.length} total · ${enabledEntries.length} enabled',
    );
    final loaded = <String>[];
    final skipped = <String>[];
    for (final entry in enabledEntries) {
      try {
        final load = _loadEntryIntoRuntime(entry, force: force);
        await (perEntryTimeout == null ? load : load.timeout(perEntryTimeout));
        loaded.add(providerKey(entry.originRepoUrl, entry.name));
      } catch (e) {
        // Includes TimeoutException: a provider whose JS load HANGS (an infinite
        // loop / flutter_js stall) is skipped rather than trapping the loop — and,
        // upstream, the splash. A provider that just throws was already skipped.
        skipped.add(entry.name);
        debugPrint('[ProviderRegistry] failed to load ${entry.name}: $e');
      }
    }
    debugPrint(
      '[ProviderRegistry] loadAll done · '
      '${loaded.length} loaded · ${skipped.length} skipped '
      '${skipped.isNotEmpty ? "(${skipped.join(", ")})" : ""}',
    );
    return loaded;
  }

  /// Loads in flight, so one source is never loaded twice at the same time.
  final Map<String, Future<bool>> _loading = {};

  /// Loads [sourceId] into the JS runtime when it is installed+enabled but not
  /// yet evaluated (e.g. a prior boot timed it out). Returns false on failure.
  Future<bool> ensureRuntimeLoaded(
    String sourceId, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    if (_manager.get(sourceId) != null) return Future.value(true);
    // One load per source at a time. On TV nothing is loaded at boot, so
    // opening a title fires several calls that all want the same provider
    // (detail, episodes, the playback prefetch). Without this each one would
    // re-download it and evaluate it into the SHARED QuickJS runtime again.
    //
    // The callback body is a BLOCK on purpose: `Map.remove` hands back the
    // future being removed, and an arrow body would return it to
    // `whenComplete`, which then waits for the very future it is completing.
    return _loading[sourceId] ??= _loadIntoRuntime(sourceId, timeout)
        .whenComplete(() {
          _loading.remove(sourceId);
        });
  }

  Future<bool> _loadIntoRuntime(String sourceId, Duration timeout) async {
    final entry = entryFor(sourceId);
    if (entry == null || !entry.enabled) return false;
    try {
      await _loadEntryIntoRuntime(entry).timeout(timeout);
      return _manager.get(sourceId) != null;
    } catch (e) {
      debugPrint(
        '[ProviderRegistry] ensureRuntimeLoaded failed for $sourceId: $e',
      );
      return false;
    }
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
      await _manager.load(
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
    await _manager.load(
      sourceId: entry.name,
      jsSource: cached.jsCode,
      originRepoUrl: entry.originRepoUrl,
      displayName: entry.displayName,
    );
  }
}
