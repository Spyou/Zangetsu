import 'dart:io';

import 'package:hive/hive.dart';

import '../aniyomi/aniyomi_extension_service.dart';
import '../aniyomi/aniyomi_update.dart';
import '../di/injector.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';

/// Background auto-updater for installed extensions across all three ecosystems
/// (Zangetsu JS, CloudStream `.cs3`, Aniyomi). Reuses each ecosystem's existing
/// update path — the same code the Sources screen's "Update" buttons call.
///
/// Every step is best-effort and wrapped so it can NEVER throw or break startup:
/// a source that fails to update simply keeps its working version. Returns the
/// total number of extensions actually updated.
class ExtensionAutoUpdater {
  ExtensionAutoUpdater._();

  // The Aniyomi repo-URL box (defined in features/sources/aniyomi_repo_tab.dart
  // as kAniyomiReposBoxName). Hardcoded here to avoid a core→features import.
  static const String _aniyomiReposBox = 'aniyomi_repos';

  static Future<int> run() async {
    var updated = 0;
    updated += await _updateZangetsu();
    // CloudStream + Aniyomi are Android-only; their managers aren't registered
    // elsewhere, so guard on registration rather than platform.
    updated += await _updateCloudStream();
    updated += await _updateAniyomi();
    return updated;
  }

  /// JS providers: re-fetch each tracked repo's manifest, then force-reinstall
  /// only the installed sources whose version went up. Mirrors
  /// SourcesBloc._onRepoUpdated, minus the UI.
  static Future<int> _updateZangetsu() async {
    if (!sl.isRegistered<ProviderReposRegistry>() ||
        !sl.isRegistered<ProviderRegistry>()) {
      return 0;
    }
    try {
      final repos = sl<ProviderReposRegistry>();
      final registry = sl<ProviderRegistry>();
      var count = 0;
      for (final tracked in repos.getAll()) {
        ProviderRepo repo;
        try {
          repo = await repos.fetchAndCache(tracked.url);
        } catch (_) {
          continue; // repo unreachable → leave its sources as-is
        }
        final installed = <String, ProviderRegistryEntry>{
          for (final e in registry.getAll())
            ProviderRegistry.providerKey(e.originRepoUrl, e.name): e,
        };
        for (final source in repo.sources) {
          final entry =
              installed[ProviderRegistry.providerKey(repo.url, source.id)];
          if (entry == null) continue;
          if (!isProviderVersionNewer(source.version, entry.version)) continue;
          try {
            await registry.install(
              sourceId: source.id,
              fileUrl: repos.resolveFileUrl(repo, source),
              logoUrl: ProviderReposRegistry.resolveLogoUrl(repo, source) ?? '',
              repoUrl: repo.url,
              displayName: source.name,
              version: source.version,
              force: true,
            );
            count++;
          } catch (_) {/* keep the working version */}
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// CloudStream: updateRepo() re-fetches + reinstalls only changed plugins and
  /// returns how many it updated.
  static Future<int> _updateCloudStream() async {
    if (!Platform.isAndroid || !sl.isRegistered<CloudStreamManager>()) return 0;
    try {
      final mgr = sl<CloudStreamManager>();
      final urls = <String>{
        for (final g in mgr.repoGroups)
          if (g.url.isNotEmpty) g.url,
      };
      var count = 0;
      for (final url in urls) {
        try {
          count += await mgr.updateRepo(url);
        } catch (_) {/* skip this repo */}
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// Aniyomi: detect updates across its repos, then install each via the same
  /// installFromRepo() the Sources screen uses.
  static Future<int> _updateAniyomi() async {
    if (!Platform.isAndroid || !sl.isRegistered<AniyomiManager>()) return 0;
    try {
      final repoUrls = Hive.isBoxOpen(_aniyomiReposBox)
          ? Hive.box<String>(_aniyomiReposBox).values.toList()
          : const <String>[];
      if (repoUrls.isEmpty) return 0;
      final mgr = sl<AniyomiManager>();
      await mgr.checkAllUpdates(repoUrls, force: true);
      final svc = AniyomiExtensionService();
      var count = 0;
      for (final url in repoUrls) {
        for (final update in List<AniyomiUpdate>.from(mgr.updatesFor(url))) {
          try {
            final res = await svc.installFromRepo(update.entry, manager: mgr);
            if (res.isNotEmpty) {
              mgr.clearUpdatesForPkg(update.pkg);
              count++;
            }
          } catch (_) {/* keep the working version */}
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}
