import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import 'lnreader_extension_service.dart';
import 'lnreader_provider.dart';
import 'lnreader_runtime.dart';

/// Owns the shared QuickJS runtime + loaded novel-source providers — the
/// novel twin of `MihonManager` (`lib/core/mihon/mihon_manager.dart`).
/// Deliberately duplicated rather than shared, same rationale as every other
/// *Reader/*Mihon twin in this codebase.
///
/// The laziness invariant this class exists to enforce: [init] only opens the
/// `lnreader_plugins` Hive box — it must NEVER build the runtime or load a
/// plugin, so a cold boot pays zero LNReader cost when the user has no novel
/// sources open. The runtime is built, and every installed plugin loaded,
/// only the first time [all] is read.
///
/// [all] is `Future`-typed, unlike `MihonManager.all` (a plain synchronous
/// getter over already-registered sources). Building the runtime and loading
/// a plugin both go through `LnReaderRuntime.loadPlugin`, which genuinely
/// awaits asset loads (the cheerio + harness JS bundles) — a real Dart
/// `await`, even against Flutter's `SynchronousFuture` test asset loader,
/// always defers past the current synchronous call, so nothing here could
/// resolve inside a plain synchronous getter body. `runtimeBuilt` still flips
/// true synchronously the moment [all] is first evaluated (the shared
/// `LnReaderRuntime` is constructed before the first `await` inside
/// [_build]), so the laziness invariant is observable without awaiting.
class LnReaderManager {
  LnReaderManager({required this.service, required this.fetch});

  final LnReaderExtensionService service;
  final Future<LnReaderHttpResponse> Function(String url, Map init) fetch;

  LnReaderRuntime? _runtime;
  Future<List<LnReaderProvider>>? _allFuture;

  /// True once the shared runtime has been constructed — a test seam for the
  /// laziness invariant (must stay false until [all] is first read).
  @visibleForTesting
  bool get runtimeBuilt => _runtime != null;

  /// Opens the `lnreader_plugins` Hive box. Does NOT build the runtime or
  /// load any plugin — see the laziness invariant above.
  Future<void> init() async {
    if (!Hive.isBoxOpen(LnReaderExtensionService.boxName)) {
      await openBoxSafely<Map>(LnReaderExtensionService.boxName);
    }
  }

  /// One [LnReaderProvider] per installed plugin, building the shared
  /// runtime and loading each plugin's JS on first read. Cached after
  /// that — re-reading returns the same providers without reloading.
  ///
  /// A plugin whose JS fails to load is skipped (logged), not fatal to the
  /// rest — same "one bad extension can't sink the batch" rule
  /// `ProviderRegistry.loadAll` follows.
  Future<List<LnReaderProvider>> get all => _allFuture ??= _build();

  /// Placeholder — LNReader has no update-check mechanism yet. Mirrors
  /// `MihonManager.updateCount`'s shape so a future update feature slots in
  /// without changing this getter's name/type.
  int get updateCount => 0;

  Future<List<LnReaderProvider>> _build() async {
    final runtime = _runtime ??= LnReaderRuntime(fetch: fetch);
    final providers = <LnReaderProvider>[];
    for (final meta in service.installed()) {
      final js = service.jsFor(meta.id);
      if (js == null) continue;
      try {
        await runtime.loadPlugin(meta.id, js);
        providers.add(
          LnReaderProvider(
            runtime: runtime,
            pluginId: meta.id,
            info: runtime.pluginInfo(meta.id),
          ),
        );
      } catch (e) {
        debugPrint('[lnreader] failed to load plugin ${meta.id}: $e');
      }
    }
    return providers;
  }
}
