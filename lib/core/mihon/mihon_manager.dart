import 'package:flutter/foundation.dart';

import 'mihon_extension_service.dart'; // also re-exports mihon_source_info.dart
import 'mihon_provider.dart';
import 'mihon_update.dart';

/// Holds all registered Mihon manga sources — the manga twin of
/// `AniyomiManager` (`lib/core/provider/provider_manager.dart:837`).
///
/// Deliberately duplicated rather than shared (spec Decision 3) so the
/// (frozen) anime path never has to change for a manga change. Lives in its
/// own file under `lib/core/mihon/` rather than inside
/// `provider_manager.dart` — that file is a 960-line shared file the anime
/// path depends on, and this manager needs none of its library-private
/// members, so there is no technical reason to risk touching it.
///
/// Stores fully-wired [MihonProvider] instances, exactly like [AniyomiManager]
/// stores `AniyomiProvider`s — [MihonSourceInfo] was only a placeholder value
/// type until `MihonProvider` (M6) existed. The `mihon:<id>` id prefix (spec
/// Decision 1 — not `ani:`, which `sourceTypeOf` hardcodes to anime) is
/// [MihonProvider.sourceId] itself, so [register]/[registerAll] key by that
/// directly, same as `AniyomiManager` keys by `AniyomiProvider.sourceId`.
/// [idFor] remains as the standalone namespacing helper (still used by
/// `installFromRepo`-adjacent tests and any caller that only has a raw id).
class MihonManager extends ChangeNotifier {
  final Map<String, MihonProvider> _sources = {};

  /// Available updates keyed by repo base URL. Mirrors AniyomiManager._updates.
  final Map<String, List<MihonUpdate>> _updates = {};

  /// Overridable checker (test seam). Defaults to the real service fetch.
  Future<List<MihonUpdate>> Function(String url, Map<String, int> codes)?
      checkerOverride;

  DateTime? _lastUpdateCheck;
  static const Duration _updatesTtl = Duration(minutes: 30);

  /// Namespaces a native `Source.id` as `mihon:<id>` (spec Decision 1).
  static String idFor(int sourceId) => 'mihon:$sourceId';

  /// Installed extension packages → versionCode, derived from registered
  /// Mihon sources (first source per pkg wins; all sources share a code).
  Map<String, int> get installedCodes {
    final m = <String, int>{};
    for (final s in _sources.values) {
      m.putIfAbsent(s.pkg, () => s.versionCode);
    }
    return m;
  }

  /// Read-only update check for a single repo; stores + notifies. Never throws.
  Future<List<MihonUpdate>> checkRepoUpdates(String url) async {
    final checker = checkerOverride ??
        (u, codes) => MihonExtensionService().checkRepoForUpdates(u, codes);
    try {
      final list = await checker(url, installedCodes);
      if (list.isEmpty) {
        _updates.remove(url);
      } else {
        _updates[url] = list;
      }
      notifyListeners();
      return list;
    } catch (_) {
      return const [];
    }
  }

  List<MihonUpdate> updatesFor(String url) => _updates[url] ?? const [];

  /// The update for [pkg] across all repos, or null.
  MihonUpdate? updateFor(String pkg) {
    for (final list in _updates.values) {
      for (final u in list) {
        if (u.pkg == pkg) return u;
      }
    }
    return null;
  }

  int get updateCount => _updates.values.fold(0, (a, l) => a + l.length);

  /// Checks every repo URL. TTL-debounced (30 min) unless [force]. Returns the
  /// total update count. Never throws.
  Future<int> checkAllUpdates(List<String> repoUrls, {bool force = false}) async {
    final last = _lastUpdateCheck;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _updatesTtl) {
      return updateCount;
    }
    _lastUpdateCheck = DateTime.now();
    for (final url in repoUrls) {
      if (url.isNotEmpty) await checkRepoUpdates(url);
    }
    return updateCount;
  }

  /// Drops [pkg] from all repos' update lists (after a successful update).
  void clearUpdatesForPkg(String pkg) {
    var changed = false;
    for (final url in _updates.keys.toList()) {
      final filtered = _updates[url]!.where((u) => u.pkg != pkg).toList();
      if (filtered.length != _updates[url]!.length) changed = true;
      if (filtered.isEmpty) {
        _updates.remove(url);
      } else {
        _updates[url] = filtered;
      }
    }
    if (changed) notifyListeners();
  }

  /// All registered Mihon providers (`mihon:*` source ids).
  List<MihonProvider> get all => _sources.values.toList();

  /// Resolves a provider by its `mihon:<sourceId>` identifier, or null when
  /// not installed.
  MihonProvider? get(String sourceId) => _sources[sourceId];

  /// Register [provider] under its [MihonProvider.sourceId]. Replaces any
  /// existing entry with the same id.
  void register(MihonProvider provider) {
    _sources[provider.sourceId] = provider;
    notifyListeners();
  }

  /// Batch-register [providers]; notifies listeners once when non-empty.
  void registerAll(List<MihonProvider> providers) {
    for (final p in providers) {
      _sources[p.sourceId] = p;
    }
    if (providers.isNotEmpty) notifyListeners();
  }

  /// Removes all providers that match [predicate] and notifies listeners when
  /// at least one was removed. Used by the uninstall flow to remove all
  /// sources that belong to a given extension package.
  void removeWhere(bool Function(MihonProvider provider) predicate) {
    final toRemove = _sources.entries
        .where((e) => predicate(e.value))
        .map((e) => e.key)
        .toList();
    for (final k in toRemove) {
      _sources.remove(k);
    }
    if (toRemove.isNotEmpty) notifyListeners();
  }
}
