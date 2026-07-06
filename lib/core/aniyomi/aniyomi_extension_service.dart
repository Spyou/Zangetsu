import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../provider/provider_manager.dart' show AniyomiManager;
import 'aniyomi_provider.dart';
import 'aniyomi_repo.dart';
import 'aniyomi_source_info.dart';
import 'aniyomi_update.dart';

export 'aniyomi_source_info.dart';

/// Dart-side wrapper around the `zangetsu/aniyomi` [MethodChannel].
///
/// Mirrors the three methods exposed by `AniyomiBridge.attach()` on the
/// Android side. All methods are thin channel invocations; no caching or
/// business logic lives here.
class AniyomiExtensionService {
  static const MethodChannel _channel = MethodChannel('zangetsu/aniyomi');

  /// Hive box name used to persist installed pkg → apk-path entries so they
  /// can be reloaded on a cold start without re-downloading.
  static const String installedBoxName = 'aniyomi_installed';

  /// Loads and registers a single extension APK located at [apkPath].
  ///
  /// Throws a [PlatformException] with code `"LOAD"` when the APK is not a
  /// valid Aniyomi anime extension or the lib version is out of range.
  Future<void> installExtension(String apkPath) async {
    await _channel.invokeMethod<void>('installExtension', {'apkPath': apkPath});
  }

  /// Loads every `*.apk` found in [dir] and registers them.
  Future<void> loadInstalled(String dir) async {
    await _channel.invokeMethod<void>('loadInstalled', {'dir': dir});
  }

  /// Returns all currently registered sources as a list of [AniyomiSourceInfo].
  ///
  /// The native bridge serialises the list as a JSON string; this method
  /// deserialises it. Returns an empty list on any decoding failure.
  Future<List<AniyomiSourceInfo>> listSources() async {
    final raw = await _channel.invokeMethod<String>('listSources');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => AniyomiSourceInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Returns the source's filter-list schema JSON (see [AniyomiFilters]), or
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
  /// ConfigurableAnimeSource and has settings to show.
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

  /// Launches the native AniyomiSettingsActivity for the source with [sourceId].
  ///
  /// No-op (returns without error) when the source has no settings.
  Future<void> openSourceSettings(int sourceId) async {
    try {
      await _channel.invokeMethod<void>('openSourceSettings', {'sourceId': sourceId});
    } on PlatformException catch (e) {
      debugPrint('[aniyomi] openSourceSettings($sourceId) failed: $e');
    }
  }

  /// Downloads the extension APK from [entry.apkUrl], installs it, then
  /// builds an [AniyomiProvider] for every new source in the package.
  ///
  /// Steps:
  /// 1. Download the APK to `<app-support>/aniyomi/<pkg>.apk` (or
  ///    [apkDirectory] when supplied, which is useful in tests).
  /// 2. Call [installExtension] over the native channel.
  /// 3. Call [listSources] and filter to sources whose [AniyomiSourceInfo.pkg]
  ///    matches [entry.pkg].
  /// 4. Persist `pkg → apk path` in the `'aniyomi_installed'` Hive box so
  ///    [loadInstalled] can restore providers on the next cold start.
  /// 5. Register each new provider in the optional [manager] (falls back to
  ///    `GetIt.instance<AniyomiManager>()` when the type is registered there).
  ///
  /// Never throws — returns `[]` on any failure and logs the error.
  ///
  /// [downloader] lets callers (and tests) substitute the download step without
  /// a real network connection. When omitted the method calls `sl<Dio>().download`.
  Future<List<AniyomiProvider>> installFromRepo(
    AniyomiRepoEntry entry, {
    Dio? dio,
    Directory? apkDirectory,
    Future<void> Function(String url, String savePath)? downloader,
    AniyomiManager? manager,
  }) async {
    try {
      // 1. Resolve the APK save directory.
      final Directory apkDir;
      if (apkDirectory != null) {
        apkDir = apkDirectory;
      } else {
        final support = await getApplicationSupportDirectory();
        apkDir = Directory('${support.path}/aniyomi');
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
        final effectiveDio =
            dio ?? GetIt.instance.get<Dio>();
        await effectiveDio.download(entry.apkUrl, apkPath);
      }

      // 3. Install and list sources.
      await installExtension(apkPath);
      final allSources = await listSources();
      final providers = allSources
          .where((s) => s.pkg == entry.pkg)
          .map((s) => AniyomiProvider(info: s))
          .toList();

      // 4. Persist pkg → apk path so loadInstalled can restore on next boot.
      if (Hive.isBoxOpen(installedBoxName)) {
        await Hive.box<dynamic>(installedBoxName).put(entry.pkg, apkPath);
      }

      // 5. Register in the AniyomiManager.
      final effectiveManager = manager ??
          (GetIt.instance.isRegistered<AniyomiManager>()
              ? GetIt.instance.get<AniyomiManager>()
              : null);
      effectiveManager?.registerAll(providers);

      return providers;
    } catch (e, st) {
      debugPrint('[aniyomi] installFromRepo(${entry.pkg}) failed: $e\n$st');
      return [];
    }
  }

  /// Read-only check: fetches [repoUrl]'s index and returns updates for every
  /// installed package whose repo `code` is newer than [installedCodes]. Never
  /// throws — a failed fetch degrades to an empty list. Does NOT download APKs.
  Future<List<AniyomiUpdate>> checkRepoForUpdates(
    String repoUrl,
    Map<String, int> installedCodes, {
    Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndex,
  }) async {
    try {
      final fetch = fetchIndex ?? AniyomiRepo.fetchIndex;
      final entries = await fetch(repoUrl);
      final out = <AniyomiUpdate>[];
      for (final e in entries) {
        final installed = installedCodes[e.pkg];
        if (installed != null && e.code > installed) {
          out.add(
            AniyomiUpdate(
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
    } catch (_) {
      return const [];
    }
  }
}
