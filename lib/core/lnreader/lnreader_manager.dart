import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import 'lnreader_extension_service.dart';
import 'lnreader_provider.dart';
import 'lnreader_runtime.dart';

/// Owns the shared QuickJS runtime + installed-plugin metadata — the novel
/// twin of `MihonManager` (`lib/core/mihon/mihon_manager.dart`). Deliberately
/// duplicated rather than shared, same rationale as every other *Reader/
/// *Mihon twin in this codebase.
///
/// The laziness invariant this class exists to enforce: neither [init] nor
/// [installedSources] nor [get] nor [metaFor] may build the runtime or load a
/// plugin — they only ever read stored [LnReaderPluginMeta]. A cold boot (or
/// registering a `LnReaderProvider` per installed source, the way
/// `SourceRepository` does for every other provider type) must pay zero
/// LNReader runtime cost when the user never opens a novel source.
///
/// The runtime is built, and a given plugin's JS loaded, only the first time
/// [ensureLoaded] (or [callPlugin], which calls it) runs for that plugin —
/// i.e. only once a `LnReaderProvider` data method is actually invoked.
/// `runtimeBuilt` flips true synchronously the moment [ensureLoaded]
/// constructs the shared [LnReaderRuntime], before its first `await`, so the
/// laziness invariant is observable without awaiting the load to finish.
class LnReaderManager {
  LnReaderManager({required this.service, required this.fetch});

  final LnReaderExtensionService service;
  final Future<LnReaderHttpResponse> Function(String url, Map init) fetch;

  LnReaderRuntime? _runtime;
  final Set<String> _loadedPluginIds = {};
  final Map<String, LnReaderProvider> _providerCache = {};

  /// True once the shared runtime has been constructed — a test seam for the
  /// laziness invariant (must stay false until [ensureLoaded] is first
  /// called).
  @visibleForTesting
  bool get runtimeBuilt => _runtime != null;

  /// Opens the `lnreader_plugins` Hive box. Does NOT build the runtime or
  /// load any plugin — see the laziness invariant above.
  Future<void> init() async {
    if (!Hive.isBoxOpen(LnReaderExtensionService.boxName)) {
      await openBoxSafely<Map>(LnReaderExtensionService.boxName);
    }
  }

  /// One `(id, name)` pair per installed plugin, straight from stored meta —
  /// what `SourceRepository` walks to register a provider per novel source.
  /// SYNC and never touches the runtime.
  List<({String id, String name})> get installedSources => [
    for (final m in service.installed()) (id: 'lnr:${m.id}', name: m.name),
  ];

  /// Looks up a [LnReaderProvider] by its `'lnr:<pluginId>'` [sourceId].
  /// SYNC — constructs (and caches) the provider straight from stored meta;
  /// never builds the runtime or loads the plugin. Returns null when the
  /// plugin isn't installed.
  LnReaderProvider? get(String sourceId) {
    final pluginId = sourceId.startsWith('lnr:') ? sourceId.substring(4) : sourceId;
    final meta = metaFor(pluginId);
    if (meta == null) return null;
    return _providerCache[pluginId] ??= LnReaderProvider(manager: this, meta: meta);
  }

  /// The stored metadata for an installed plugin, or null. SYNC.
  LnReaderPluginMeta? metaFor(String pluginId) {
    for (final m in service.installed()) {
      if (m.id == pluginId) return m;
    }
    return null;
  }

  /// Placeholder — LNReader has no update-check mechanism yet. Mirrors
  /// `MihonManager.updateCount`'s shape so a future update feature slots in
  /// without changing this getter's name/type.
  int get updateCount => 0;

  /// Builds the shared runtime (first call only) and loads [pluginId]'s JS
  /// into it (first call per plugin only) — the ONLY place besides
  /// [callPlugin] that does either. Every `LnReaderProvider` data method
  /// awaits this before touching the plugin.
  Future<void> ensureLoaded(String pluginId) async {
    if (_loadedPluginIds.contains(pluginId)) return;
    final js = service.jsFor(pluginId);
    if (js == null) {
      throw StateError('lnreader plugin "$pluginId" is not installed');
    }
    final runtime = _runtime ??= LnReaderRuntime(fetch: fetch);
    await runtime.loadPlugin(pluginId, js);
    _loadedPluginIds.add(pluginId);
  }

  /// Ensures [pluginId] is loaded, then calls `plugin[method](...args)`.
  Future<dynamic> callPlugin(String pluginId, String method, List<Object?> args) async {
    await ensureLoaded(pluginId);
    return _runtime!.call(pluginId, method, args);
  }

  /// The plugin's own filter schema (`pluginInfo()['filters']`), forwarded
  /// verbatim into `popularNovels` as its default `filters` argument —
  /// confirmed required by the Phase-0 spike (`proven_harness.js`), not
  /// optional the way it is for e.g. Mihon search. Only valid after
  /// [ensureLoaded] has resolved for [pluginId]; returns `{}` if the plugin
  /// carries no filter schema.
  Map<String, dynamic> filtersFor(String pluginId) {
    final filters = _runtime?.pluginInfo(pluginId)['filters'];
    return filters is Map ? Map<String, dynamic>.from(filters) : {};
  }
}
