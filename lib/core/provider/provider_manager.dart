import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';

import '../error/exceptions.dart';
import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import 'base_provider.dart';
import 'crypto_ops.dart';
import 'js_bootstrap.dart';

enum ProviderHealthStatus { healthy, degraded, broken }

class _ProviderHealth {
  _ProviderHealth({required this.failures, required this.lastError, required this.status});
  final int failures;
  final String lastError;
  final ProviderHealthStatus status;
}

/// Single shared QuickJS runtime hosting every provider as
/// `__providers[sourceId]` and every extractor as `__extractors[host]`.
class _JsHost {
  _JsHost({required this.dio}) {
    _runtime = getJavascriptRuntime();
    _runtime.enableHandlePromises();
    _runtime.onMessage('fetch', _onFetch);
    _runtime.onMessage('console', _onConsole);
    _runtime.onMessage('crypto', _onCrypto);
    _runtime.onMessage('timer', _onTimer);
    final r = _runtime.evaluate(kJsBootstrap);
    if (r.isError) {
      throw JsRuntimeException('Bootstrap failed: ${r.stringResult}');
    }
  }

  final Dio dio;
  late final JavascriptRuntime _runtime;
  final Map<String, JsProvider> providers = {};
  final Map<String, _ProviderHealth> _health = {};

  ProviderHealthStatus healthFor(String sourceId) =>
      _health[sourceId]?.status ?? ProviderHealthStatus.healthy;
  String? lastErrorFor(String sourceId) => _health[sourceId]?.lastError;
  int failuresFor(String sourceId) => _health[sourceId]?.failures ?? 0;
  void resetHealth(String sourceId) => _health.remove(sourceId);

  void loadProvider(String sourceId, String jsSource) {
    final r = _runtime.evaluate(wrapProviderSource(sourceId, jsSource));
    if (r.isError) {
      throw JsRuntimeException('Provider eval failed for $sourceId: ${r.stringResult}');
    }
  }

  void loadExtractor(String extractorId, String jsSource) {
    final r = _runtime.evaluate(wrapExtractorSource(extractorId, jsSource));
    if (r.isError) {
      throw JsRuntimeException('Extractor eval failed for $extractorId: ${r.stringResult}');
    }
  }

  void removeProvider(String sourceId) {
    _runtime.evaluate('delete globalThis.__providers[${jsonEncode(sourceId)}];');
  }

  Future<String> call(String sourceId, String method, List<Object?> args,
      {Duration timeout = const Duration(seconds: 15)}) async {
    try {
      final v = await _runCall(sourceId, method, args, timeout);
      _health.remove(sourceId);
      return v;
    } catch (e) {
      final failures = (_health[sourceId]?.failures ?? 0) + 1;
      _health[sourceId] = _ProviderHealth(
        failures: failures,
        lastError: e.toString(),
        status: failures >= 3 ? ProviderHealthStatus.broken : ProviderHealthStatus.degraded,
      );
      rethrow;
    }
  }

  Future<String> _runCall(String sourceId, String method, List<Object?> args,
      Duration timeout) async {
    final argsJson = jsonEncode(args);
    final expr =
        '__callProvider(${jsonEncode(sourceId)}, ${jsonEncode(method)}, ${jsonEncode(argsJson)})';
    final asyncResult = await _runtime.evaluateAsync(expr);
    final resolved = await _runtime
        .handlePromise(asyncResult)
        .timeout(timeout, onTimeout: () {
      throw JsRuntimeException('$method timed out after ${timeout.inSeconds}s');
    });
    if (resolved.isError) {
      var msg = resolved.stringResult;
      if (msg.startsWith('"') && msg.endsWith('"')) {
        try { final unq = jsonDecode(msg); if (unq is String) msg = unq; } catch (_) {}
      }
      throw JsRuntimeException(msg);
    }
    var s = resolved.stringResult;
    if (s.isEmpty || s == 'null') {
      throw JsRuntimeException('$sourceId.$method returned null');
    }
    if (s.startsWith('"') && s.endsWith('"')) {
      try { final u = jsonDecode(s); if (u is String) s = u; } catch (_) {}
    }
    return s;
  }

  Map<String, dynamic> _coerceMap(dynamic raw) {
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw FormatException('Unexpected message payload type: ${raw.runtimeType}');
  }

  Future<void> _onFetch(dynamic raw) async {
    String? id;
    try {
      final payload = _coerceMap(raw);
      id = payload['id'] as String;
      final url = payload['url'] as String;
      final method = (payload['method'] as String?) ?? 'GET';
      final headers = (payload['headers'] as Map?)?.cast<String, dynamic>() ?? {};
      final body = payload['body'];
      final tMs = (payload['timeoutMs'] as num?)?.toInt() ?? 0;
      // ignore: avoid_print
      print('[fetch] $method $url');
      final resp = await dio.requestUri<dynamic>(
        Uri.parse(url),
        data: body,
        options: Options(
          method: method,
          headers: headers.map((k, v) => MapEntry(k, v.toString())),
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (_) => true,
          receiveTimeout: tMs > 0 ? Duration(milliseconds: tMs) : null,
          sendTimeout: tMs > 0 ? Duration(milliseconds: tMs) : null,
        ),
      );
      // ignore: avoid_print
      print('[fetch] <- ${resp.statusCode} ${(resp.data?.toString().length ?? 0)}B $url');
      final responseHeaders = <String, String>{};
      resp.headers.forEach((k, v) => responseHeaders[k] = v.join(', '));
      final responseJson = jsonEncode({
        'status': resp.statusCode ?? 0,
        'statusText': resp.statusMessage ?? '',
        'headers': responseHeaders,
        'url': resp.realUri.toString(),
        'body': resp.data?.toString() ?? '',
      });
      _runtime.evaluate('__resolveFetch(${jsonEncode(id)}, ${jsonEncode(responseJson)});');
    } catch (e) {
      // ignore: avoid_print
      print('[fetch] FAILED $e');
      if (id != null) {
        _runtime.evaluate('__rejectFetch(${jsonEncode(id)}, ${jsonEncode(e.toString())});');
      }
    }
  }

  void _onCrypto(dynamic raw) {
    String? id;
    try {
      final payload = _coerceMap(raw);
      id = payload['id'] as String;
      final op = payload['op'] as String;
      String result;
      if (op == 'sha256') {
        result = sha256Hex(payload['message'] as String);
      } else if (op == 'aesCtrDecrypt') {
        final data = base64Decode(payload['dataB64'] as String);
        result = aesCtrDecryptToString(
          keyHex: payload['keyHex'] as String,
          counterHex: payload['counterHex'] as String,
          data: Uint8List.fromList(data),
        );
      } else {
        throw FormatException('Unknown crypto op: $op');
      }
      _runtime.evaluate('__resolveCrypto(${jsonEncode(id)}, ${jsonEncode(result)});');
    } catch (e) {
      if (id != null) {
        _runtime.evaluate('__rejectCrypto(${jsonEncode(id)}, ${jsonEncode(e.toString())});');
      }
    }
  }

  void _onTimer(dynamic raw) {
    try {
      final payload = _coerceMap(raw);
      final id = payload['id'] as String;
      final ms = (payload['ms'] as num?)?.toInt() ?? 0;
      Future<void>.delayed(Duration(milliseconds: ms < 0 ? 0 : ms), () {
        _runtime.evaluate('__fireTimer(${jsonEncode(id)});');
      });
    } catch (_) {}
  }

  void _onConsole(dynamic raw) {
    try {
      final map = _coerceMap(raw);
      final src = (map['__src'] ?? '?').toString();
      final level = (map['level'] ?? 'log').toString();
      final message = (map['message'] ?? '').toString();
      // ignore: avoid_print
      print('[$src/js $level] $message');
    } catch (_) {}
  }

  void dispose() => _runtime.dispose();
}

/// Thin per-source wrapper. Calls route through the shared _JsHost and
/// deserialize into the video models.
class JsProvider implements BaseProvider {
  JsProvider._({
    required this.sourceId,
    required this.originRepoUrl,
    required this.displayName,
    required _JsHost host,
  }) : _host = host;

  @override
  final String sourceId;
  final String originRepoUrl;
  final String displayName;
  final _JsHost _host;

  ProviderHealthStatus get healthStatus => _host.healthFor(sourceId);
  String? get lastError => _host.lastErrorFor(sourceId);

  Future<String> _call(String method, List<Object?> args,
          {Duration timeout = const Duration(seconds: 15)}) =>
      _host.call(sourceId, method, args, timeout: timeout);

  ProviderInfo? _infoCache;

  @override
  Future<ProviderInfo> getInfo() async {
    final cached = _infoCache;
    if (cached != null) return cached;
    final raw = await _call('getInfo', const []);
    final info = ProviderInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    _infoCache = info;
    return info;
  }

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    final raw = await _call('popular', [
      {'category': category, 'dateRange': dateRange, 'page': page}
    ]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((m) => MediaItem.fromJson({...m, 'sourceId': sourceId})).toList();
  }

  @override
  Future<List<MediaItem>> search(String query, int page, {String category = ''}) async {
    final raw = await _call('search', [query, page, {'category': category}]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((m) => MediaItem.fromJson({...m, 'sourceId': sourceId})).toList();
  }

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    final raw = await _call('getDetail', [url, {'category': category}]);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return MediaDetail.fromJson({...map, 'sourceId': sourceId});
  }

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) async {
    final raw = await _call('getEpisodes', [url, {'category': category}]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(Episode.fromJson).toList();
  }

  @override
  Future<List<VideoSource>> getVideoSources(String episodeUrl) async {
    // Video source resolution makes several network hops (decrypt + multiple
    // embed/clock resolves), so it needs a longer ceiling than the 15s default.
    final raw = await _call('getVideoSources', [episodeUrl],
        timeout: const Duration(seconds: 60));
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(VideoSource.fromJson).toList();
  }
}

/// Public manager. Owns the single shared QuickJS runtime + registered
/// providers and extractors.
class ProviderManager {
  ProviderManager({required Dio dio}) : _host = _JsHost(dio: dio);

  final _JsHost _host;

  Iterable<String> get installedIds => _host.providers.keys;
  List<JsProvider> get all => _host.providers.values.toList();
  JsProvider? get(String id) => _host.providers[id];

  /// Loads [jsSource] as a provider under [sourceId]. One provider per
  /// sourceId is live at a time; reloading replaces it.
  JsProvider load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) {
    _host.loadProvider(sourceId, jsSource);
    final provider = JsProvider._(
      sourceId: sourceId,
      originRepoUrl: originRepoUrl,
      displayName: displayName,
      host: _host,
    );
    _host.providers[sourceId] = provider;
    return provider;
  }

  /// Loads [jsSource] as an extractor; it registers itself under each host
  /// in its getInfo().hosts list and is reachable via extractVideo().
  void loadExtractor({required String extractorId, required String jsSource}) {
    _host.loadExtractor(extractorId, jsSource);
  }

  void remove(String id) {
    _host.removeProvider(id);
    _host.providers.remove(id);
    _host.resetHealth(id);
  }

  void disposeAll() {
    _host.providers.clear();
    _host.dispose();
  }
}
