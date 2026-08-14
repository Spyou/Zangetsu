import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../aniyomi/aniyomi_repo.dart';
import 'mihon_manager.dart';
import 'mihon_provider.dart';
import 'mihon_repo.dart';
import 'mihon_source_info.dart';
import 'mihon_update.dart';

export 'mihon_source_info.dart';

/// Dart-side wrapper around the `zangetsu/mihon` [MethodChannel].
///
/// Structural twin of `AniyomiExtensionService`
/// (`lib/core/aniyomi/aniyomi_extension_service.dart`) — deliberately
/// duplicated rather than shared (spec Decision 3). Covers 6 of the 13
/// methods `MihonBridge.attach()` exposes: `installExtension`,
/// `loadInstalled`, `listSources`, `getFilterList`, `hasSourceSettings`,
/// `openSourceSettings`. The other 7 (`getPopular`, `getLatest`, `search`,
/// `getDetails`, `getChapters`, `getPages`, `getImage`) are per-source data
/// calls that belong to `MihonProvider` (`mihon_provider.dart`) — out of
/// scope here. All methods below are thin channel invocations; no caching or
/// business logic lives here.
///
/// [AniyomiRepoEntry] (`lib/core/aniyomi/aniyomi_repo.dart`) is reused
/// UNMODIFIED as the entry type, but the index is read by [MihonRepo], not
/// `AniyomiRepo`: Mihon repos publish `index.json` in a different shape (see
/// `mihon_repo.dart`).
class MihonExtensionService {
  static const MethodChannel _channel = MethodChannel('zangetsu/mihon');

  /// Hive box name used to persist installed pkg → apk-path entries so they
  /// can be reloaded on a cold start without re-downloading. Deliberately
  /// separate from `AniyomiExtensionService.installedBoxName`
  /// (`'aniyomi_installed'`) so the two extension families never collide.
  static const String installedBoxName = 'mihon_installed';

  /// Loads and registers a single extension APK located at [apkPath].
  ///
  /// Throws a [PlatformException] with code `"LOAD"` when the APK is not a
  /// valid Mihon manga extension or the lib version is out of range.
  Future<void> installExtension(String apkPath) async {
    await _channel.invokeMethod<void>('installExtension', {'apkPath': apkPath});
  }

  /// Loads every `*.apk` found in [dir] and registers them.
  Future<void> loadInstalled(String dir) async {
    await _channel.invokeMethod<void>('loadInstalled', {'dir': dir});
  }

  /// Returns all currently registered sources as a list of [MihonSourceInfo].
  ///
  /// The native bridge serialises the list as a JSON string; this method
  /// deserialises it. Returns an empty list on any decoding failure.
  Future<List<MihonSourceInfo>> listSources() async {
    final raw = await _channel.invokeMethod<String>('listSources');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => MihonSourceInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Returns the source's filter-list schema JSON (see `MihonFilters`), or
  /// null when the source has no filters or any channel error occurs.
  Future<String?> getFilterList(int sourceId) async {
    try {
      return await _channel.invokeMethod<String>(
        'getFilterList',
        {'sourceId': sourceId},
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Returns true when the native source with [sourceId] implements
  /// ConfigurableSource and has settings to show.
  ///
  /// Returns false on any channel error (source not found, not configurable).
  Future<bool> hasSourceSettings(int sourceId) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'hasSourceSettings',
        {'sourceId': sourceId},
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Launches the native MihonSettingsActivity for the source with [sourceId].
  ///
  /// No-op (returns without error) when the source has no settings.
  Future<void> openSourceSettings(int sourceId) async {
    try {
      await _channel.invokeMethod<void>('openSourceSettings', {'sourceId': sourceId});
    } on PlatformException catch (e) {
      debugPrint('[mihon] openSourceSettings($sourceId) failed: $e');
    }
  }

  /// Opens the native visible WebView (MihonCloudflareActivity) so the user can
  /// complete a Cloudflare challenge for [url]. The `cf_clearance` cookie it
  /// captures is shared with the Mihon OkHttp client, so the source loads
  /// afterwards. Best-effort — a missing channel (non-Android) is a silent no-op.
  static Future<void> solveCloudflare(String url) async {
    try {
      await _channel.invokeMethod<void>('solveCloudflare', {'url': url});
    } on PlatformException catch (e) {
      debugPrint('[mihon] solveCloudflare failed: $e');
    } on MissingPluginException {
      // Non-Android host — no native solver.
    }
  }

  /// Downloads the extension APK from [entry.apkUrl], installs it, then
  /// builds a [MihonProvider] for every new source in the package.
  ///
  /// Steps:
  /// 1. Download the APK to `<app-support>/mihon/<pkg>.apk` (or
  ///    [apkDirectory] when supplied, which is useful in tests).
  /// 2. Call [installExtension] over the native channel.
  /// 3. Call [listSources] and filter to sources whose [MihonSourceInfo.pkg]
  ///    matches [entry.pkg].
  /// 4. Persist `pkg → apk path` in the `'mihon_installed'` Hive box so
  ///    [loadInstalled] can restore sources on the next cold start.
  /// 5. Register each new provider in the optional [manager] (falls back to
  ///    `GetIt.instance<MihonManager>()` when the type is registered there).
  ///
  /// Never throws — returns `[]` on any failure and logs the error.
  ///
  /// [downloader] lets callers (and tests) substitute the download step without
  /// a real network connection. When omitted the method calls `sl<Dio>().download`.
  Future<List<MihonProvider>> installFromRepo(
    AniyomiRepoEntry entry, {
    Dio? dio,
    Directory? apkDirectory,
    Future<void> Function(String url, String savePath)? downloader,
    MihonManager? manager,
  }) async {
    try {
      // 1. Resolve the APK save directory.
      final Directory apkDir;
      if (apkDirectory != null) {
        apkDir = apkDirectory;
      } else {
        final support = await getApplicationSupportDirectory();
        apkDir = Directory('${support.path}/mihon');
      }
      await apkDir.create(recursive: true);
      final apkPath = '${apkDir.path}/${entry.pkg}.apk';

      // A prior load marks the apk read-only (Android W^X), which would block
      // re-downloading over it — remove any stale copy first.
      final existingApk = File(apkPath);
      if (await existingApk.exists()) {
        try {
          await existingApk.delete();
        } catch (_) {}
      }

      // 2. Download the APK.
      if (downloader != null) {
        await downloader(entry.apkUrl, apkPath);
      } else {
        final effectiveDio = dio ?? GetIt.instance.get<Dio>();
        await _downloadApk(effectiveDio, entry.apkUrl, apkPath);
      }

      // 3. Install and list sources.
      await installExtension(apkPath);
      final allSources = await listSources();
      final providers = allSources
          .where((s) => s.pkg == entry.pkg)
          .map((s) => MihonProvider(info: s))
          .toList();

      // 4. Persist pkg → apk path so loadInstalled can restore on next boot.
      if (Hive.isBoxOpen(installedBoxName)) {
        await Hive.box<dynamic>(installedBoxName).put(entry.pkg, apkPath);
      }

      // 5. Register in the MihonManager.
      final effectiveManager = manager ??
          (GetIt.instance.isRegistered<MihonManager>()
              ? GetIt.instance.get<MihonManager>()
              : null);
      effectiveManager?.registerAll(providers);

      return providers;
    } catch (e, st) {
      debugPrint('[mihon] installFromRepo(${entry.pkg}) failed: $e\n$st');
      return [];
    }
  }

  /// Extension APKs are multi-MB, but the shared Dio is tuned for small API
  /// calls (8s receiveTimeout) — the #1 cause of "No source loaded" on the
  /// anime side was that timeout firing mid-download on slow connections (the
  /// tiny repo index still loads, so the list looks fine). Give the download a
  /// generous timeout, and if the direct raw.githubusercontent.com fetch fails
  /// (ISP blocks / rate limits), retry via a GitHub-raw mirror.
  static const Duration _apkDownloadTimeout = Duration(minutes: 3);

  /// The shared Dio connects in 8s, which is right for browsing — a search
  /// fans out across every source, so a host that won't answer should be
  /// dropped fast. It's wrong for an install: that's one deliberate tap the
  /// user is waiting on, and a repo whose APKs live off-site (Keiyoushi now
  /// redirects to GitHub Releases) makes the phone establish TWO connections,
  /// each rolling that dice on a weak signal.
  static const Duration _apkConnectTimeout = Duration(seconds: 30);

  Future<void> _downloadApk(Dio dio, String url, String savePath) async {
    final opts = Options(
      receiveTimeout: _apkDownloadTimeout,
      sendTimeout: _apkDownloadTimeout,
      connectTimeout: _apkConnectTimeout,
    );
    // Try the direct URL first, then every GitHub-raw mirror in turn. Some
    // phones/ISPs block raw.githubusercontent.com but can reach the CDNs/proxies,
    // and any single mirror can be missing a file, so we fall through the
    // whole list — same rationale as the anime download path.
    final urls = <String>[url, ...githubMirrors(url)];
    Object? lastError;
    for (final u in urls) {
      try {
        await dio.download(u, savePath, options: opts);
        return; // first success wins
      } on DioException catch (e) {
        lastError = e;
        debugPrint(
          '[mihon] download mirror failed '
          '(${e.response?.statusCode ?? e.type}): $u',
        );
      }
    }
    throw lastError ?? Exception('all download mirrors failed');
  }

  /// Read-only check: fetches [repoUrl]'s index and returns updates for every
  /// installed package whose repo `code` is newer than [installedCodes]. Never
  /// throws — a failed fetch degrades to an empty list. Does NOT download APKs.
  Future<List<MihonUpdate>> checkRepoForUpdates(
    String repoUrl,
    Map<String, int> installedCodes, {
    Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndex,
  }) async {
    try {
      final fetch = fetchIndex ?? MihonRepo.fetchIndex;
      final entries = await fetch(repoUrl);
      final out = <MihonUpdate>[];
      for (final e in entries) {
        final installed = installedCodes[e.pkg];
        if (installed != null && e.code > installed) {
          out.add(
            MihonUpdate(
              pkg: e.pkg,
              name: e.name,
              installedCode: installed,
              availableCode: e.code,
              availableVersion: e.version,
              entry: e,
            ),
          );
        }
      }
      return out;
    } catch (e) {
      debugPrint('[mihon] checkRepoForUpdates($repoUrl) failed: $e');
      return const [];
    }
  }
}

/// GitHub-raw download mirrors, tried in order after the direct fetch fails
/// (some phones/ISPs block raw.githubusercontent.com but reach these). Returns
/// an empty list for non-GitHub-raw URLs. Structural twin of the anime path's
/// `githubMirrors()` in `aniyomi_extension_service.dart` — duplicated per spec
/// Decision 3, not imported, so the frozen anime file never has to change.
List<String> githubMirrors(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host != 'raw.githubusercontent.com') return const [];
  final segs = u.pathSegments;
  if (segs.length < 4) return const [];
  final owner = segs[0];
  final repo = segs[1];
  final ref = segs[2];
  final path = segs.sublist(3).join('/');
  return [
    'https://cdn.jsdelivr.net/gh/$owner/$repo@$ref/$path',
    'https://gh-proxy.com/$url',
    'https://cdn.statically.io/gh/$owner/$repo/$ref/$path',
  ];
}
