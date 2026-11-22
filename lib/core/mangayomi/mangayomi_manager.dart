import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

import '../error/exceptions.dart';
import '../models/source_pref.dart';
import '../provider/cf_solve_needed.dart';
import '../update/update_service.dart';
import 'mangayomi_provider.dart';

class MangayomiManager extends ChangeNotifier {
  MangayomiManager(this.service);

  final MangayomiExtensionService service;
  final Map<String, InstalledMangayomiSource> _installed = {};
  final Map<Uri, List<MangayomiSource>> _catalogues = {};
  final Map<String, MangayomiProvider> _providers = {};
  final LinkedHashMap<String, _WorkerEntry> _workers = LinkedHashMap();
  final Map<String, Future<MangayomiRuntimeWorker>> _workerLoads = {};
  final FlutterSecureStorage _settings = const FlutterSecureStorage();
  List<Uri> _repositories = const [];
  var _initialized = false;
  var revision = 0;

  List<InstalledMangayomiSource> get installed =>
      List.unmodifiable(_installed.values);
  List<Uri> get repositories => List.unmodifiable(_repositories);
  List<MangayomiSource> get updates => mangayomiOutdatedSources(
    _installed.values,
    _catalogues.values.expand((sources) => sources),
  );
  int get updateCount => updates.length;

  Future<void> init() async {
    if (_initialized) return;
    _repositories = await service.repositories();
    for (final item in await service.installed()) {
      _installed[item.source.key] = item;
    }
    _initialized = true;
  }

  MangayomiProvider? get(String sourceId) {
    final item = _installed[sourceId];
    if (item == null) return null;
    return _providers.putIfAbsent(
      sourceId,
      () => MangayomiProvider(manager: this, installed: item),
    );
  }

  List<MangayomiProvider> get all =>
      _installed.keys.map(get).whereType<MangayomiProvider>().toList();

  MangayomiSource? sourceFor(String sourceId) => _installed[sourceId]?.source;

  List<MangayomiSource> catalogueFor(Uri repository) =>
      List.unmodifiable(_catalogues[repository] ?? const []);

  Future<List<MangayomiSource>> addRepository(Uri url) async {
    final sources = await service.addRepository(url);
    _repositories = await service.repositories();
    _catalogues[url] = sources;
    notifyListeners();
    return sources;
  }

  Future<List<MangayomiSource>> refreshRepository(Uri url) async {
    final sources = await service.refreshRepository(url);
    _catalogues[url] = sources;
    notifyListeners();
    return sources;
  }

  Future<void> removeRepository(Uri url) async {
    await service.removeRepository(url);
    _repositories = await service.repositories();
    _catalogues.remove(url);
    notifyListeners();
  }

  Future<void> install(MangayomiSource source) async {
    final item = await service.install(source);
    await _dropWorker(source.key);
    _installed[source.key] = item;
    _providers.remove(source.key);
    _changed();
  }

  Future<void> uninstall(String sourceId) async {
    await service.uninstall(sourceId);
    await _dropWorker(sourceId);
    _installed.remove(sourceId);
    _providers.remove(sourceId);
    try {
      await _settings.delete(key: 'mangayomi:$sourceId');
    } catch (_) {}
    _changed();
  }

  Future<Map<String, dynamic>> _savedSettings(String sourceId) async {
    try {
      final raw = await _settings.read(key: 'mangayomi:$sourceId');
      return raw == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<List<SourcePref>> sourcePreferences(String sourceId) async {
    List<dynamic> raw;
    try {
      raw = await run(sourceId, (worker) => worker.getSourcePreferences());
    } catch (error) {
      // Sources that never declare preferences have NO settings, not an
      // error — the JS base source throws "getSourcePreferences not
      // implemented" for them. Anything else is a real failure.
      if (!error.toString().contains('not implemented')) rethrow;
      raw = const [];
    }
    final saved = await _savedSettings(sourceId);
    return [
      for (final item in raw)
        if (item is Map && item['key'] is String)
          SourcePref.fromMap({
            ...item,
            'values': item['entryValues'] ?? item['values'] ?? const [],
            'value': saved.containsKey(item['key'])
                ? saved[item['key']]
                : item['value'],
          }),
    ];
  }

  Future<bool> setSourcePreference(
    String sourceId,
    String key,
    Object? value,
  ) async {
    try {
      final saved = await _savedSettings(sourceId);
      saved[key] = value;
      await _settings.write(
        key: 'mangayomi:$sourceId',
        value: jsonEncode(saved),
      );
      await _dropWorker(sourceId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<T> run<T>(
    String sourceId,
    Future<T> Function(MangayomiRuntimeWorker worker) operation,
  ) async {
    final entry = await _workerEntry(sourceId);
    entry.active++;
    try {
      return await operation(entry.worker);
    } on StateError catch (error, stackTrace) {
      final url = mangayomiCloudflareChallengeUrl(error);
      if (url == null) Error.throwWithStackTrace(error, stackTrace);
      CfSolveNeeded.needsSolve(Uri.parse(url).host, url, sourceId: sourceId);
      Error.throwWithStackTrace(CloudflareRequiredException(url), stackTrace);
    } finally {
      entry.active--;
      await _trimWorkers();
    }
  }

  Future<MangayomiRuntimeWorker> _loadWorker(String sourceId) async {
    final item = _installed[sourceId];
    if (item == null) throw StateError('Mangayomi source is not installed');
    final code = await item.codeFile.readAsString();
    return MangayomiRuntimeWorker(
      item.source.toRuntimeSource(),
      code,
      item.source.codeLanguage,
      preferences: await _savedSettings(sourceId),
    );
  }

  Future<_WorkerEntry> _workerEntry(String sourceId) async {
    final existing = _workers.remove(sourceId);
    if (existing != null) {
      _workers[sourceId] = existing;
      return existing;
    }
    final worker = await (_workerLoads[sourceId] ??= _loadWorker(sourceId));
    _workerLoads.remove(sourceId);
    return _workers.putIfAbsent(sourceId, () => _WorkerEntry(worker));
  }

  Future<void> _trimWorkers() async {
    while (_workers.length > 2) {
      final idleKey = _workers.keys.firstWhere(
        (key) => _workers[key]!.active == 0,
        orElse: () => '',
      );
      if (idleKey.isEmpty) return;
      final entry = _workers.remove(idleKey)!;
      await entry.worker.dispose();
    }
  }

  Future<void> _dropWorker(String sourceId) async {
    final entry = _workers.remove(sourceId);
    _workerLoads.remove(sourceId);
    if (entry != null) await entry.worker.dispose();
  }

  void _changed() {
    revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final entry in _workers.values) {
      entry.worker.dispose();
    }
    _workers.clear();
    service.dispose();
    super.dispose();
  }
}

@visibleForTesting
String? mangayomiCloudflareChallengeUrl(Object error) {
  if (error is! StateError) return null;
  const marker = 'Cloudflare challenge at ';
  final message = error.toString();
  final markerIndex = message.indexOf(marker);
  if (markerIndex < 0) return null;
  final url = message.substring(markerIndex + marker.length).trim();
  final uri = Uri.tryParse(url);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return url;
}

class _WorkerEntry {
  _WorkerEntry(this.worker);
  final MangayomiRuntimeWorker worker;
  int active = 0;
}

/// Catalogue entries whose version no longer matches the installed copy —
/// the sources an "update extensions" pass should install.
List<MangayomiSource> mangayomiOutdatedSources(
  Iterable<InstalledMangayomiSource> installed,
  Iterable<MangayomiSource> catalogue,
) {
  final byKey = {for (final source in catalogue) source.key: source};
  return [
    for (final item in installed)
      if (byKey[item.source.key] case final source?
          when mangayomiVersionIsNewer(source.version, item.source.version))
        source,
  ];
}

bool mangayomiVersionIsNewer(String available, String installed) =>
    UpdateService.compareVersions(available, installed) > 0;
