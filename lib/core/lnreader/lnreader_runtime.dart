import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';

/// A single HTTP response as seen by an LNReader plugin's fetchApi/@libs/fetch.
class LnReaderHttpResponse {
  const LnReaderHttpResponse({
    required this.status,
    required this.body,
    required this.url,
  });

  final int status;
  final String body;
  final String url;
}

/// Isolated, lazily-built QuickJS runtime that runs LNReader (CommonJS)
/// novel-source plugins on top of the committed cheerio bundle + require()
/// harness. Deliberately separate from ProviderManager's shared JS host:
/// LNReader plugins are a different module shape (require()-based, not the
/// CloudStream-style wrapped closures) and don't share its settings/CF/health
/// bookkeeping.
///
/// flutter_js's JS<->Dart message channel (sendMessage/onMessage) only works
/// on a real device, not the host QuickJS FFI runtime used by `flutter test`.
/// So the harness's fetchApi pushes requests into a JS-side outbox instead,
/// and [call] drives resolution itself: pump the JS event loop, drain the
/// outbox, run the injected [fetch] for each request, feed the result back
/// with `__resolveFetch`, repeat until the call's result lands.
class LnReaderRuntime {
  LnReaderRuntime({
    required Future<LnReaderHttpResponse> Function(String url, Map init)
    fetch,
  }) : _fetch = fetch;

  final Future<LnReaderHttpResponse> Function(String url, Map init) _fetch;

  JavascriptRuntime? _rt;
  int _callSeq = 0;

  /// Builds the engine and evaluates the cheerio bundle + harness on first
  /// call; a no-op on every call after.
  Future<void> ensureReady() async {
    if (_rt != null) return;
    final rt = getJavascriptRuntime(xhr: false);
    final cheerio = await rootBundle.loadString(
      'assets/js/lnreader_cheerio.js',
    );
    final harness = await rootBundle.loadString(
      'assets/js/lnreader_harness.js',
    );
    final cheerioResult = rt.evaluate(cheerio);
    if (cheerioResult.isError) {
      rt.dispose();
      throw StateError(
        'lnreader cheerio bundle failed: ${cheerioResult.stringResult}',
      );
    }
    final harnessResult = rt.evaluate(harness);
    if (harnessResult.isError) {
      rt.dispose();
      throw StateError('lnreader harness failed: ${harnessResult.stringResult}');
    }
    _rt = rt;
  }

  /// Loads a CommonJS plugin source under [pluginId]. Returns the plugin's
  /// `name`, or throws if it fails to evaluate / has no default export.
  Future<String> loadPlugin(String pluginId, String jsSource) async {
    await ensureReady();
    final r = _rt!.evaluate(
      '__loadPlugin(${jsonEncode(pluginId)}, ${jsonEncode(jsSource)})',
    );
    if (r.isError) {
      throw StateError(
        'lnreader loadPlugin($pluginId) failed: ${r.stringResult}',
      );
    }
    return r.stringResult;
  }

  /// Reads a loaded plugin's `{name, site, version, filters}`. Must be
  /// called after [loadPlugin] has resolved for [pluginId].
  Map<String, dynamic> pluginInfo(String pluginId) {
    final rt = _rt;
    if (rt == null) {
      throw StateError('lnreader runtime not ready — call loadPlugin() first');
    }
    final r = rt.evaluate('__pluginInfo(${jsonEncode(pluginId)})');
    if (r.isError) {
      throw StateError(
        'lnreader pluginInfo($pluginId) failed: ${r.stringResult}',
      );
    }
    return jsonDecode(r.stringResult) as Map<String, dynamic>;
  }

  /// Calls `plugin[method](...args)` and returns the JSON-decoded result.
  Future<dynamic> call(
    String pluginId,
    String method,
    List<Object?> args,
  ) async {
    await ensureReady();
    final rt = _rt!;
    final id = ++_callSeq;
    rt.evaluate(
      "globalThis.__calls=globalThis.__calls||{}; globalThis.__calls[$id]={done:false,result:null};"
      " __callPlugin(${jsonEncode(pluginId)},${jsonEncode(method)},${jsonEncode(jsonEncode(args))}).then("
      " function(r){globalThis.__calls[$id]={done:true,result:r};},"
      " function(e){globalThis.__calls[$id]={done:true,result:JSON.stringify({__error:String((e&&e.message)||e)})};});",
    );
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 30)) {
      rt.executePendingJob();
      final drained = rt.evaluate('__drainOutbox()').stringResult;
      for (final req in jsonDecode(drained) as List) {
        final map = req as Map<String, dynamic>;
        final reqId = map['id'];
        final url = map['url'] as String;
        final init = (map['init'] as Map?) ?? {};
        // Fire-and-forget: whichever later loop iteration is running when
        // this future completes drains the resolve back into the runtime.
        _fetch(url, init).then((resp) {
          rt.evaluate(
            '__resolveFetch(${jsonEncode(reqId)}, ${jsonEncode(jsonEncode({'status': resp.status, 'body': resp.body, 'url': resp.url}))});',
          );
        });
      }
      final doneFlag = rt
          .evaluate(
            '(globalThis.__calls[$id]&&globalThis.__calls[$id].done)?"1":"0"',
          )
          .stringResult;
      if (doneFlag == '1') {
        final raw = rt.evaluate('globalThis.__calls[$id].result').stringResult;
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['__error'] != null) {
          throw StateError(decoded['__error'].toString());
        }
        return decoded;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw TimeoutException('lnreader call timed out');
  }

  void dispose() {
    _rt?.dispose();
    _rt = null;
  }
}
