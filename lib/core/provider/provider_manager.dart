import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';

import '../aniyomi/aniyomi_extension_service.dart';
import '../aniyomi/aniyomi_provider.dart';
import '../aniyomi/aniyomi_update.dart';
import '../error/exceptions.dart';
import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import 'base_provider.dart';
import 'cf_clearance_store.dart';
import 'crypto_ops.dart';
import 'js_bootstrap.dart';

enum ProviderHealthStatus { healthy, degraded, broken }

class _ProviderHealth {
  _ProviderHealth({
    required this.failures,
    required this.lastError,
    required this.status,
  });
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

  // Serialize every provider call onto ONE queue. flutter_js/QuickJS is single-
  // threaded and non-reentrant; overlapping calls race its async FFI callback
  // ("Callback invoked after it has been deleted" → native SIGABRT, the frequent
  // crash). Running calls strictly one-at-a-time removes that race. The runtime's
  // OWN re-entrant resolves (__resolveFetch/__fireTimer/__resolveCrypto) do NOT
  // take this lock, so an in-flight call can still be fed while it pumps the JS
  // event loop — i.e. this can't deadlock.
  Future<void> _callQueue = Future<void>.value();

  // Cloudflare bridge: JS providers opt into a CF-cleared request via
  // fetch(url, { browser: true }). We reuse the native WebView solver (the same
  // one the CloudStream side uses) over a MethodChannel and cache the solved
  // clearance cookie + matching User-Agent per host. Android-only; on platforms
  // without the handler the invoke throws and we fall back to a plain request.
  static const MethodChannel _cf = MethodChannel('zangetsu/cloudstream');
  final Map<String, String> _cfCookie = {}; // host -> cf_clearance cookie(s)
  final Map<String, String> _cfUa = {}; // host -> the solving User-Agent
  // Persists solved clearances across restarts so a JS source cleared once
  // doesn't re-pop the "Verifying…" solver every fresh session (the CS path gets
  // this for free via the CookieManager jar; the Dart Dio client does not).
  final CfClearanceStore _cfStore = CfClearanceStore();
  bool _cfRestored = false; // hydrate the in-memory maps from disk once, lazily
  // Negative cache: hosts where a solve just failed (e.g. a dead/parked domain
  // that never yields a clearance cookie). Without this, every browser:true
  // request re-runs the ~30s WebView solve and the app hangs for minutes. We
  // attempt at most once per host per [_cfFailTtlMs], then fall through to a
  // plain request so the provider fails fast instead of looping the solver.
  final Map<String, int> _cfFailedAt = {}; // host -> ms of last failed solve
  // 30 min: a source we can't clear (e.g. an interactive/Turnstile challenge)
  // must NOT re-pop the solver every couple of minutes — that's the "verifying
  // again and again" the user sees. One attempt, then leave it alone for a while.
  static const int _cfFailTtlMs = 1800000; // 30 min
  // In-flight solves keyed by host: concurrent requests (e.g. getHome fetching
  // several pages at once) share ONE 30s WebView solve instead of each spawning
  // its own — otherwise a single page load fires N parallel solvers.
  final Map<String, Future<void>> _cfInflight = {};

  // While a `search` runs, never pop the blocking CF WebView solver: search is
  // a passive multi-source sweep, so a background source's challenge must not
  // hijack the screen. Cached clearance is still applied; an unsolved CF source
  // just returns nothing for search. The solve happens later, when the user
  // actually opens/plays from that source.
  bool _suppressCfSolve = false;
  final Map<String, _ProviderHealth> _health = {};

  ProviderHealthStatus healthFor(String sourceId) =>
      _health[sourceId]?.status ?? ProviderHealthStatus.healthy;
  String? lastErrorFor(String sourceId) => _health[sourceId]?.lastError;
  int failuresFor(String sourceId) => _health[sourceId]?.failures ?? 0;
  void resetHealth(String sourceId) => _health.remove(sourceId);

  void loadProvider(String sourceId, String jsSource) {
    final r = _runtime.evaluate(wrapProviderSource(sourceId, jsSource));
    if (r.isError) {
      throw JsRuntimeException(
        'Provider eval failed for $sourceId: ${r.stringResult}',
      );
    }
  }

  void loadExtractor(String extractorId, String jsSource) {
    final r = _runtime.evaluate(wrapExtractorSource(extractorId, jsSource));
    if (r.isError) {
      throw JsRuntimeException(
        'Extractor eval failed for $extractorId: ${r.stringResult}',
      );
    }
  }

  void removeProvider(String sourceId) {
    _runtime.evaluate(
      'delete globalThis.__providers[${jsonEncode(sourceId)}];',
    );
  }

  /// Pushes [settings] into the JS runtime as `__settings[sourceId]`.
  /// One-shot sync eval — best-effort, never throws. Replaces the slot
  /// entirely so cleared keys disappear from the JS side too. Providers
  /// read it as `__settings[__SOURCE_ID]` inside their wrapped closure.
  void setSettings(String sourceId, Map<String, dynamic> settings) {
    final r = _runtime.evaluate(
      '__settings[${jsonEncode(sourceId)}] = ${jsonEncode(settings)};',
    );
    if (r.isError) {
      // ignore: avoid_print
      print('[settings] push failed for $sourceId: ${r.stringResult}');
    }
  }

  // Chains [action] after the current queue tail so calls run strictly one at a
  // time; a failing call still releases the queue (errors are swallowed on the
  // chaining future, propagated only to the caller). See [_callQueue].
  Future<T> _serialized<T>(Future<T> Function() action) {
    final done = Completer<T>();
    final prev = _callQueue;
    _callQueue = done.future.then<void>((_) {}, onError: (_) {});
    prev.whenComplete(
      () => action().then(done.complete, onError: done.completeError),
    );
    return done.future;
  }

  Future<String> call(
    String sourceId,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final v = await _serialized(
        () => _runCall(sourceId, method, args, timeout),
      );
      _health.remove(sourceId);
      return v;
    } catch (e) {
      final failures = (_health[sourceId]?.failures ?? 0) + 1;
      _health[sourceId] = _ProviderHealth(
        failures: failures,
        lastError: e.toString(),
        status: failures >= 3
            ? ProviderHealthStatus.broken
            : ProviderHealthStatus.degraded,
      );
      rethrow;
    }
  }

  Future<String> _runCall(
    String sourceId,
    String method,
    List<Object?> args,
    Duration timeout,
  ) async {
    final wasSuppress = _suppressCfSolve;
    _suppressCfSolve = method == 'search';
    try {
      final argsJson = jsonEncode(args);
      final expr =
          '__callProvider(${jsonEncode(sourceId)}, ${jsonEncode(method)}, ${jsonEncode(argsJson)})';
      final asyncResult = await _runtime.evaluateAsync(expr);
      final resolved = await _runtime
          .handlePromise(asyncResult)
          .timeout(
            timeout,
            onTimeout: () {
              throw JsRuntimeException(
                '$method timed out after ${timeout.inSeconds}s',
              );
            },
          );
      if (resolved.isError) {
        var msg = resolved.stringResult;
        if (msg.startsWith('"') && msg.endsWith('"')) {
          try {
            final unq = jsonDecode(msg);
            if (unq is String) msg = unq;
          } catch (_) {}
        }
        throw JsRuntimeException(msg);
      }
      var s = resolved.stringResult;
      if (s.isEmpty || s == 'null') {
        throw JsRuntimeException('$sourceId.$method returned null');
      }
      if (s.startsWith('"') && s.endsWith('"')) {
        try {
          final u = jsonDecode(s);
          if (u is String) s = u;
        } catch (_) {}
      }
      return s;
    } finally {
      _suppressCfSolve = wasSuppress;
    }
  }

  Map<String, dynamic> _coerceMap(dynamic raw) {
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw FormatException(
      'Unexpected message payload type: ${raw.runtimeType}',
    );
  }

  Future<void> _onFetch(dynamic raw) async {
    String? id;
    try {
      final payload = _coerceMap(raw);
      id = payload['id'] as String;
      final url = payload['url'] as String;
      final method = (payload['method'] as String?) ?? 'GET';
      final headers =
          (payload['headers'] as Map?)?.cast<String, dynamic>() ?? {};
      final body = payload['body'];
      final tMs = (payload['timeoutMs'] as num?)?.toInt() ?? 0;
      final follow = payload['followRedirects'] != false;
      final wantCf = payload['browser'] == true || payload['cf'] == true;
      final host = Uri.parse(url).host;
      final hdr = headers.map((k, v) => MapEntry(k, v.toString()));
      _ensureCfRestored(); // reuse a clearance solved in a previous session
      // Opt-in Cloudflare clearance: solve once per host, then attach cookie+UA.
      // Skip if a recent solve failed (negative cache) so a dead/parked host
      // doesn't re-run the 30s solver on every request.
      if (wantCf &&
          !_suppressCfSolve &&
          !_cfCookie.containsKey(host) &&
          !_cfRecentlyFailed(host)) {
        await _solveCf(url, host);
      }
      _applyCf(host, hdr);
      // Did the original request carry a clearance? If so and it STILL gets
      // challenged below, that clearance is stale (e.g. a persisted cookie that
      // expired) and must be dropped rather than reused.
      final sentClearance = _cfCookie.containsKey(host);
      // ignore: avoid_print
      print('[fetch] $method $url${wantCf ? ' (cf)' : ''}');
      var resp = await _request(url, method, hdr, body, follow, tMs);
      // Auto-recover from a Cloudflare challenge even without the opt-in flag:
      // solve (once) and replay with the clearance. CRUCIALLY, also replay when
      // the cookie was JUST solved by a concurrent fetch for this host — without
      // this, that fetch returns the challenge ("couldn't load") and only a
      // manual retry (which reuses the now-cached cookie) succeeds.
      if (_looksLikeCfChallenge(resp) && !_suppressCfSolve) {
        // A challenge despite a clearance WE sent means it's stale → forget it
        // (memory + disk) so the solve re-runs. A cookie a concurrent fetch just
        // solved (sentClearance == false) is fresh — keep it and just replay.
        if (sentClearance && _cfCookie.containsKey(host)) {
          _cfCookie.remove(host);
          _cfStore.forget(host);
        }
        if (!_cfCookie.containsKey(host) && !_cfRecentlyFailed(host)) {
          await _solveCf(url, host);
        }
        if (_cfCookie.containsKey(host)) {
          _applyCf(host, hdr);
          resp = await _request(url, method, hdr, body, follow, tMs);
        }
      }
      // ignore: avoid_print
      print(
        '[fetch] <- ${resp.statusCode} ${(resp.data?.toString().length ?? 0)}B $url',
      );
      final responseHeaders = <String, String>{};
      resp.headers.forEach((k, v) => responseHeaders[k] = v.join(', '));
      final responseJson = jsonEncode({
        'status': resp.statusCode ?? 0,
        'statusText': resp.statusMessage ?? '',
        'headers': responseHeaders,
        'url': resp.realUri.toString(),
        'body': resp.data?.toString() ?? '',
      });
      _runtime.evaluate(
        '__resolveFetch(${jsonEncode(id)}, ${jsonEncode(responseJson)});',
      );
    } catch (e) {
      // ignore: avoid_print
      print('[fetch] FAILED $e');
      if (id != null) {
        _runtime.evaluate(
          '__rejectFetch(${jsonEncode(id)}, ${jsonEncode(e.toString())});',
        );
      }
    }
  }

  Future<Response<dynamic>> _request(
    String url,
    String method,
    Map<String, String> headers,
    dynamic body,
    bool follow,
    int tMs,
  ) {
    return dio.requestUri<dynamic>(
      Uri.parse(url),
      data: body,
      options: Options(
        method: method,
        headers: headers,
        responseType: ResponseType.plain,
        followRedirects: follow,
        maxRedirects: follow ? 5 : 0,
        validateStatus: (_) => true,
        receiveTimeout: tMs > 0 ? Duration(milliseconds: tMs) : null,
        sendTimeout: tMs > 0 ? Duration(milliseconds: tMs) : null,
      ),
    );
  }

  /// Solve Cloudflare for [host] via the native WebView solver and cache the
  /// clearance cookie + matching UA. Best-effort; silent on failure or on
  /// platforms without the native handler (the MethodChannel invoke throws).
  /// Solve CF for [host], deduping concurrent callers onto one in-flight solve.
  Future<void> _solveCf(String url, String host) {
    final existing = _cfInflight[host];
    if (existing != null) return existing; // a solve for this host is running
    final fut = _solveCfImpl(url, host).whenComplete(() {
      _cfInflight.remove(host);
    });
    _cfInflight[host] = fut;
    return fut;
  }

  Future<void> _solveCfImpl(String url, String host) async {
    try {
      final res = await _cf.invokeMapMethod<String, dynamic>(
        'solveCloudflare',
        {'url': url},
      );
      final cookie = res?['cookie'] as String?;
      final ua = res?['userAgent'] as String?;
      if (cookie != null && cookie.isNotEmpty) {
        _cfCookie[host] = cookie;
        _cfFailedAt.remove(host); // solved → clear any negative-cache mark
        if (ua != null && ua.isNotEmpty) _cfUa[host] = ua;
        _cfStore.remember(host, cookie, ua); // reuse across restarts
        // ignore: avoid_print
        print('[cf] solved $host (ua=${(ua ?? '').split(')').first})');
      } else {
        // Solver returned no clearance (dead/parked host, or not a real CF
        // challenge) → mark failed so we don't re-run the 30s solve every call.
        _cfFailedAt[host] = DateTime.now().millisecondsSinceEpoch;
      }
    } catch (_) {
      // No native solver (iOS / not wired) or the invoke threw → also mark
      // failed; we fall back to a plain request.
      _cfFailedAt[host] = DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// Hydrate the in-memory CF maps from the persistent store once, on first use.
  /// Restored clearances are optimistic: a stale one is dropped + re-solved by
  /// the fetch path, so this only saves a solve when a still-valid one exists.
  void _ensureCfRestored() {
    if (_cfRestored) return;
    _cfRestored = true;
    _cfStore.restore().forEach((host, e) {
      _cfCookie.putIfAbsent(host, () => e.cookie);
      final ua = e.ua;
      if (ua != null && ua.isNotEmpty) _cfUa.putIfAbsent(host, () => ua);
    });
  }

  /// True if a CF solve for [host] failed within the last [_cfFailTtlMs].
  bool _cfRecentlyFailed(String host) {
    final at = _cfFailedAt[host];
    if (at == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - at < _cfFailTtlMs) return true;
    _cfFailedAt.remove(host); // TTL elapsed → allow a fresh attempt
    return false;
  }

  /// Merge the cached CF clearance into [hdr]. The cf_clearance cookie is bound
  /// to the EXACT User-Agent that solved it, so when we have one we must FORCE
  /// the solving UA — even over a UA the provider set — or Cloudflare 403s the
  /// mismatch. Without a CF cookie we leave the provider's UA untouched.
  void _applyCf(String host, Map<String, String> hdr) {
    final cookie = _cfCookie[host];
    final ua = _cfUa[host];
    if (cookie != null) {
      final existing = hdr['Cookie'] ?? hdr['cookie'];
      hdr['Cookie'] = (existing == null || existing.isEmpty)
          ? cookie
          : '$existing; $cookie';
      if (ua != null && ua.isNotEmpty) {
        // Force the solving UA: drop any provider-set variant, then set ours.
        hdr.remove('user-agent');
        hdr['User-Agent'] = ua;
      }
    } else if (ua != null &&
        hdr['User-Agent'] == null &&
        hdr['user-agent'] == null) {
      hdr['User-Agent'] = ua;
    }
  }

  /// True when a response is a Cloudflare interstitial rather than real content.
  bool _looksLikeCfChallenge(Response<dynamic> resp) {
    final code = resp.statusCode ?? 0;
    if (code != 403 && code != 503) return false;
    final server = (resp.headers.value('server') ?? '').toLowerCase();
    final bodyText = (resp.data?.toString() ?? '').toLowerCase();
    return server.contains('cloudflare') ||
        bodyText.contains('just a moment') ||
        bodyText.contains('challenge-platform') ||
        bodyText.contains('cf-chl') ||
        bodyText.contains('enable javascript and cookies');
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
      _runtime.evaluate(
        '__resolveCrypto(${jsonEncode(id)}, ${jsonEncode(result)});',
      );
    } catch (e) {
      if (id != null) {
        _runtime.evaluate(
          '__rejectCrypto(${jsonEncode(id)}, ${jsonEncode(e.toString())});',
        );
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
  @override
  final String displayName;
  final _JsHost _host;

  ProviderHealthStatus get healthStatus => _host.healthFor(sourceId);
  String? get lastError => _host.lastErrorFor(sourceId);

  Future<String> _call(
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 15),
  }) => _host.call(sourceId, method, args, timeout: timeout);

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

  /// CloudStream-style home rows. Returns the provider's own named sections,
  /// or `null` when the JS file doesn't define `getHome` (the caller then
  /// synthesizes default rows from [popular]). Never returns partial garbage:
  /// items without the basics are dropped, empty/untitled sections are kept
  /// out. Given a generous timeout since it may fan out several listing calls.
  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async {
    try {
      final raw = await _call('getHome', [
        {'category': category},
      ], timeout: const Duration(seconds: 30));
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <HomeSection>[];
      for (final s in decoded) {
        if (s is! Map) continue;
        final m = Map<String, dynamic>.from(s);
        final title = (m['title'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        final rawItems = m['items'];
        final items = <MediaItem>[];
        if (rawItems is List) {
          for (final e in rawItems) {
            if (e is Map) {
              items.add(
                MediaItem.fromJson({
                  ...Map<String, dynamic>.from(e),
                  'sourceId': sourceId,
                }),
              );
            }
          }
        }
        out.add(HomeSection(title: title, items: items));
      }
      return out;
    } catch (e) {
      final msg = e is JsRuntimeException ? e.message : e.toString();
      // The bootstrap signals an absent function with this exact phrase.
      if (msg.contains('missing method: getHome')) return null;
      rethrow;
    }
  }

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    final raw = await _call('popular', [
      {'category': category, 'dateRange': dateRange, 'page': page},
    ]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list
        .map((m) => MediaItem.fromJson({...m, 'sourceId': sourceId}))
        .toList();
  }

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) async {
    final raw = await _call('search', [
      query,
      page,
      {'category': category},
    ]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list
        .map((m) => MediaItem.fromJson({...m, 'sourceId': sourceId}))
        .toList();
  }

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
    // 30s: some providers enrich detail with extra metadata round-trips
    // (e.g. TMDB episode names/stills) on top of the page fetch.
    final raw = await _call('getDetail', [
      url,
      {'category': category},
    ], timeout: const Duration(seconds: 30));
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return MediaDetail.fromJson({...map, 'sourceId': sourceId});
  }

  @override
  Future<List<Episode>> getEpisodes(
    String url, {
    String category = 'sub',
  }) async {
    final raw = await _call('getEpisodes', [
      url,
      {'category': category},
    ]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(Episode.fromJson).toList();
  }

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false, // JS providers resolve in one call; no incremental mode.
  }) async {
    // Video source resolution makes several network hops (decrypt + multiple
    // embed/clock resolves), so it needs a longer ceiling than the 15s default.
    final raw = await _call('getVideoSources', [
      episodeUrl,
    ], timeout: const Duration(seconds: 60));
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(VideoSource.fromJson).toList();
  }

  /// Returns the provider's raw settings schema (the JSON list returned
  /// by its `getSettings()`), or null if the JS file doesn't define
  /// `getSettings`. Never throws — the wrapped namespace sets the slot
  /// to `null` for providers without the function, which `__callProvider`
  /// reports as a "missing method" rejection; we treat that as "no
  /// schema". Parse the result with `ProviderSettingSchema.parseAll`.
  Future<List<dynamic>?> getSettingsSchema() async {
    try {
      final raw = await _call('getSettings', const []);
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
      return null;
    } catch (e) {
      final msg = e is JsRuntimeException ? e.message : e.toString();
      // The bootstrap signals an absent function with this exact prefix.
      if (msg.contains('missing method: getSettings')) return null;
      // ignore: avoid_print
      print('[settings] schema load failed for $sourceId: $msg');
      return null;
    }
  }
}

/// Minimal contract the [ProviderRegistry] needs from a runtime host.
/// Lets tests inject a no-op loader without spinning up native QuickJS.
abstract class ProviderRuntimeLoader {
  JsProvider? get(String id);

  /// Loads [jsSource] into the runtime under [sourceId]. Return type is
  /// `void` here so test doubles needn't fabricate a [JsProvider]; the
  /// concrete [ProviderManager] still returns the loaded provider.
  void load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl,
    String displayName,
  });

  /// Pushes per-source settings into the runtime as `__settings[sourceId]`.
  void setSettings(String sourceId, Map<String, dynamic> settings);

  void remove(String id);
}

/// Public manager. Owns the single shared QuickJS runtime + registered
/// providers and extractors.
class ProviderManager implements ProviderRuntimeLoader {
  ProviderManager({required Dio dio}) : _host = _JsHost(dio: dio);

  final _JsHost _host;

  Iterable<String> get installedIds => _host.providers.keys;
  List<JsProvider> get all => _host.providers.values.toList();
  @override
  JsProvider? get(String id) => _host.providers[id];

  /// Loads [jsSource] as a provider under [sourceId]. One provider per
  /// sourceId is live at a time; reloading replaces it.
  @override
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

  /// Mirrors per-source settings into the JS runtime so subsequent
  /// provider calls can read them as `__settings[sourceId]`. Safe to
  /// call any time — the underlying eval is single-shot and best-effort.
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) =>
      _host.setSettings(sourceId, settings);

  @override
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

// ── Aniyomi provider registry ────────────────────────────────────────────────

/// Holds all registered Aniyomi source providers — the counterpart to
/// [CloudStreamManager] for the native Aniyomi extension bridge.
///
/// Providers are added at install time via [registerAll] and reloaded on cold
/// start by the guarded boot step in [initDependencies]. All runtime state is
/// in-memory; the persistence record (pkg → apk path) lives in the
/// `'aniyomi_installed'` Hive box managed by [AniyomiExtensionService].
class AniyomiManager extends ChangeNotifier {
  final Map<String, BaseProvider> _providers = {};

  /// Available updates keyed by repo base URL. Mirrors CloudStreamManager._updates.
  final Map<String, List<AniyomiUpdate>> _updates = {};

  /// Overridable checker (test seam). Defaults to the real service fetch.
  Future<List<AniyomiUpdate>> Function(String url, Map<String, int> codes)?
      checkerOverride;

  DateTime? _lastUpdateCheck;
  static const Duration _updatesTtl = Duration(minutes: 30);

  /// Installed extension packages → versionCode, derived from registered
  /// Aniyomi providers (first source per pkg wins; all sources share a code).
  Map<String, int> get installedCodes {
    final m = <String, int>{};
    for (final p in _providers.values) {
      if (p is AniyomiProvider) {
        m.putIfAbsent(p.info.pkg, () => p.info.versionCode);
      }
    }
    return m;
  }

  /// Read-only update check for a single repo; stores + notifies. Never throws.
  Future<List<AniyomiUpdate>> checkRepoUpdates(String url) async {
    final checker = checkerOverride ??
        (u, codes) => AniyomiExtensionService().checkRepoForUpdates(u, codes);
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

  List<AniyomiUpdate> updatesFor(String url) => _updates[url] ?? const [];

  /// The update for [pkg] across all repos, or null.
  AniyomiUpdate? updateFor(String pkg) {
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

  /// All registered Aniyomi providers (`ani:*` source ids).
  List<BaseProvider> get all => _providers.values.toList();

  /// Resolves a provider by its `ani:<sourceId>` identifier, or null when not
  /// installed.
  BaseProvider? get(String sourceId) => _providers[sourceId];

  /// Register [provider] under its [BaseProvider.sourceId]. Replaces any
  /// existing entry with the same id.
  void register(BaseProvider provider) {
    _providers[provider.sourceId] = provider;
    notifyListeners();
  }

  /// Batch-register [providers]; notifies listeners once when non-empty.
  void registerAll(List<BaseProvider> providers) {
    for (final p in providers) {
      _providers[p.sourceId] = p;
    }
    if (providers.isNotEmpty) notifyListeners();
  }

  /// Removes all providers that match [predicate] and notifies listeners when
  /// at least one was removed.  Used by the uninstall flow to remove all
  /// sources that belong to a given extension package.
  void removeWhere(bool Function(BaseProvider provider) predicate) {
    final toRemove = _providers.entries
        .where((e) => predicate(e.value))
        .map((e) => e.key)
        .toList();
    for (final k in toRemove) {
      _providers.remove(k);
    }
    if (toRemove.isNotEmpty) notifyListeners();
  }
}
