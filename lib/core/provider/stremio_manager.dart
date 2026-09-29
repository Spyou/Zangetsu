import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:dio/dio.dart';

import '../hive/safe_box.dart';
import 'stremio_provider.dart';

/// Persisted registry for Stremio HTTP addons.
class StremioManager extends ChangeNotifier {
  static const boxName = 'stremio_addons';
  static const _urlsKey = 'urls';

  StremioManager({required Dio dio}) : _dio = dio;

  final Dio _dio;
  final Map<String, StremioProvider> _providers = {};
  final List<String> _urls = [];

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;
  List<String> get urls => List.unmodifiable(_urls);
  List<StremioProvider> get all => List.unmodifiable(_providers.values);

  StremioProvider? get(String sourceId) => _providers[sourceId];

  Future<void> loadInstalled() async {
    _urls
      ..clear()
      ..addAll(((_box?.get(_urlsKey) as List?) ?? const []).cast<String>());
    for (final url in _urls) {
      _providers[url] = StremioProvider(baseUrl: url, dio: _dio);
    }
    notifyListeners();
  }

  Future<StremioProvider> add(String url) async {
    final provider = StremioProvider(baseUrl: url, dio: _dio);
    await provider.manifest;
    if (!_urls.contains(provider.baseUrl)) _urls.add(provider.baseUrl);
    _providers[provider.baseUrl] = provider;
    await _box?.put(_urlsKey, _urls);
    notifyListeners();
    return provider;
  }

  Future<void> remove(String url) async {
    final normalized = StremioProvider.normalizeBase(url);
    _urls.remove(normalized);
    _providers.remove(normalized);
    await _box?.put(_urlsKey, _urls);
    notifyListeners();
  }
}
