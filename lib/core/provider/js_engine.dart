import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

import '../error/exceptions.dart';
import 'js_bootstrap.dart';

/// The four channels the bootstrap talks back on.
const List<String> kJsChannels = ['fetch', 'console', 'crypto', 'timer'];

/// One evaluation's outcome, flattened to strings so it can cross a port.
class JsResult {
  const JsResult(this.value, {this.isError = false});
  final String value;
  final bool isError;
}

/// Receives what the runtime sends out on [kJsChannels].
typedef JsChannelSink = void Function(String channel, dynamic payload);

/// The QuickJS/JavaScriptCore runtime that hosts every JS provider. Behind an
/// interface because it runs in one of two places — see [JsEngine.new].
///
/// Why it moved: flutter_js's `handlePromise` pumps the JS event loop from a
/// 20ms `Timer.periodic` calling `executePendingJob()`, which runs JS
/// SYNCHRONOUSLY on whichever isolate called it. So for the whole life of
/// every provider call, each regex, HTML parse and JSON decode inside it
/// landed on the UI isolate in 20ms-spaced chunks.
///
/// Measured on device: 20s of JS on its own isolate cost the UI nothing — all
/// 1285 of its 16ms ticks still arrived. The same work inline delivered zero.
///
/// That is what `PlaybackResolver.defaultPerSourceBudget` was really bounding:
/// not a source's patience, but how long the screen could be frozen.
abstract class JsEngine {
  /// True when provider JS runs on its own isolate, so time spent inside it
  /// is no longer time the UI cannot draw.
  ///
  /// Read by [PlaybackResolver] to decide how long a source the viewer
  /// explicitly picked may take. Where this is false the old, tight budget has
  /// to stand — the wait would be a frozen screen.
  static bool get runsOffUiIsolate =>
      debugRunsOffUiIsolateOverride ?? Platform.isAndroid;

  /// Lets a test pretend either way — the host `flutter test` runs on is not
  /// Android, so without this the isolate-only behaviour is unreachable.
  @visibleForTesting
  static bool? debugRunsOffUiIsolateOverride;

  factory JsEngine({required JsChannelSink onChannel, bool polling = false}) {
    // Android only for now. Apple runs JavaScriptCore, whose FFI callback
    // already cannot re-enter Dart while evaluate() holds the engine on
    // physical tvOS (hence __usePollingBridge in js_bootstrap.dart). Until
    // that can be tested on real hardware it keeps the runtime it has always
    // had — same isolate, same behaviour.
    return runsOffUiIsolate
        ? _IsolateEngine(onChannel, polling: polling)
        : _InProcessEngine(onChannel, polling: polling);
  }

  /// Completes once the bootstrap has evaluated; fails if it could not.
  Future<void> get ready;

  /// Fire-and-forget eval, ordered against every other message. For the
  /// injections that have no result worth waiting on — `__resolveFetch`,
  /// `__fireTimer`, settings pushes.
  void post(String js);

  /// Eval whose result the caller needs.
  Future<JsResult> eval(String js);

  /// `evaluateAsync` + `handlePromise`: the provider-call path.
  Future<JsResult> callAsync(String js, Duration timeout);

  void dispose();
}

/// Builds the runtime, wires the channels, evaluates the bootstrap. Shared by
/// both engines so there is exactly one copy of the setup.
JavascriptRuntime _buildRuntime({
  required bool xhr,
  required bool polling,
  required void Function(String channel, dynamic payload) onChannel,
}) {
  final rt = xhr ? getJavascriptRuntime() : getJavascriptRuntime(xhr: false);
  rt.enableHandlePromises();
  for (final channel in kJsChannels) {
    rt.onMessage(channel, (raw) {
      // Never do work re-entrantly inside sendMessage: the callback fires
      // while evaluate() still owns the JS engine lock, and awaiting anything
      // from there deadlocks it before evaluate() can return.
      scheduleMicrotask(() => onChannel(channel, raw));
    });
  }
  final r = rt.evaluate(kJsBootstrap);
  if (r.isError) {
    throw JsRuntimeException('Bootstrap failed: ${r.stringResult}');
  }
  if (polling) rt.evaluate('globalThis.__usePollingBridge = true;');
  return rt;
}

/// The runtime on the calling isolate — what the app did everywhere before,
/// and still does on Apple and in tests.
class _InProcessEngine implements JsEngine {
  _InProcessEngine(this._onChannel, {required bool polling}) {
    try {
      _rt = _buildRuntime(xhr: true, polling: polling, onChannel: _onChannel);
      _ready.complete();
    } catch (e) {
      _dead = e;
      _ready.completeError(e);
      // Nothing may ever await `ready` — keep the error from going unhandled.
      _ready.future.catchError((_) {});
    }
  }

  final JsChannelSink _onChannel;
  final Completer<void> _ready = Completer<void>();

  /// Null until the runtime is built, and stays null if it could not be. Not
  /// `late final`: every later call would then fail with a
  /// LateInitializationError naming this field, which says nothing about the
  /// bootstrap error that actually caused it.
  JavascriptRuntime? _rt;
  Object? _dead;

  JavascriptRuntime get _engine {
    final rt = _rt;
    if (rt == null) throw _dead ?? JsRuntimeException('JS engine unavailable');
    return rt;
  }

  @override
  Future<void> get ready => _ready.future;

  @override
  void post(String js) {
    if (_rt == null) return; // best-effort by contract, like the isolate engine
    _rt!.evaluate(js);
  }

  @override
  Future<JsResult> eval(String js) async {
    final r = _engine.evaluate(js);
    return JsResult(r.stringResult, isError: r.isError);
  }

  @override
  Future<JsResult> callAsync(String js, Duration timeout) async {
    final rt = _engine;
    final async = await rt.evaluateAsync(js);
    final resolved = await rt.handlePromise(async).timeout(timeout);
    return JsResult(resolved.stringResult, isError: resolved.isError);
  }

  @override
  void dispose() {
    _rt?.dispose();
    _rt = null;
  }
}

// ── The isolate-backed engine ────────────────────────────────────────────────

/// Body of the JS isolate. Top-level, as `Isolate.spawn` requires.
void _jsIsolateMain(List<Object?> args) {
  final toHost = args[0] as SendPort;
  final polling = args[1] as bool;
  final inbox = ReceivePort();
  toHost.send(inbox.sendPort);

  final JavascriptRuntime rt;
  try {
    // xhr:false — flutter_js's enableFetch() reads a JS asset through
    // rootBundle, which needs a binding this isolate does not have. The
    // bootstrap brings its own fetch, and no provider uses XMLHttpRequest.
    rt = _buildRuntime(
      xhr: false,
      polling: polling,
      onChannel: (channel, raw) {
        // QuickJS hands the payload back already jsonDecode'd; re-encode so
        // only primitives cross the port. The host's _coerceMap takes either.
        try {
          toHost.send({
            't': 'ch',
            'c': channel,
            'p': raw is String ? raw : jsonEncode(raw),
          });
        } catch (e) {
          // A payload that will not encode would otherwise take the whole
          // message with it, and the JS promise waiting on it would hang.
          debugPrint('[js-isolate] dropped a $channel message: $e');
        }
      },
    );
  } catch (e) {
    toHost.send({'t': 'boot', 'err': '$e'});
    return;
  }
  toHost.send({'t': 'boot', 'err': null});

  inbox.listen((msg) async {
    final m = msg as Map;
    switch (m['op']) {
      case 'post':
        try {
          rt.evaluate(m['js'] as String);
        } catch (e) {
          // Not routed through the console channel: that one carries a JSON
          // payload the host decodes, and a bare string would be swallowed.
          debugPrint('[js-isolate] post failed: $e');
        }
      case 'eval':
        // Every branch must answer. A throw here would leave the caller's
        // completer pending forever, and `eval` — unlike `call` — carries no
        // deadline of its own.
        try {
          final r = rt.evaluate(m['js'] as String);
          toHost.send({
            't': 'res',
            'id': m['id'],
            'v': r.stringResult,
            'e': r.isError,
          });
        } catch (e) {
          toHost.send({'t': 'res', 'id': m['id'], 'v': '$e', 'e': true});
        }
      case 'call':
        // Deliberately not awaited: a second call must be able to arrive and
        // be pumped while this one is still pending. _JsHost's _callQueue is
        // what keeps QuickJS from being entered re-entrantly.
        unawaited(() async {
          try {
            final async = await rt.evaluateAsync(m['js'] as String);
            final resolved = await rt
                .handlePromise(async)
                .timeout(Duration(milliseconds: m['ms'] as int));
            toHost.send({
              't': 'res',
              'id': m['id'],
              'v': resolved.stringResult,
              'e': resolved.isError,
            });
          } catch (e) {
            toHost.send({'t': 'res', 'id': m['id'], 'v': '$e', 'e': true});
          }
        }());
      case 'stop':
        rt.dispose();
        inbox.close();
    }
  });
}

/// The runtime on its own isolate, driven over a port.
class _IsolateEngine implements JsEngine {
  _IsolateEngine(this._onChannel, {required bool polling}) {
    _spawn(polling);
  }

  final JsChannelSink _onChannel;
  final ReceivePort _fromIso = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<JsResult>> _pending = {};

  /// Messages posted before the isolate handed back its port. Ordering is the
  /// whole contract here — a `__resolveFetch` that overtakes the call it
  /// belongs to resolves nothing.
  final List<Map<String, Object?>> _queued = [];

  Isolate? _isolate;
  SendPort? _toIso;
  int _seq = 0;
  bool _disposed = false;

  /// Set when the isolate could not start or its bootstrap failed. The isolate
  /// never begins listening in that case, so without this every call would sit
  /// on the port until its own timeout — turning one broken engine into a
  /// screenful of 15-second waits.
  Object? _dead;

  Future<void> _spawn(bool polling) async {
    _fromIso.listen(_onMessage);
    try {
      _isolate = await Isolate.spawn(
        _jsIsolateMain,
        [_fromIso.sendPort, polling],
        onError: _fromIso.sendPort,
        onExit: _fromIso.sendPort,
        errorsAreFatal: false,
      );
    } catch (e) {
      _fail(e);
    }
  }

  void _onMessage(dynamic msg) {
    // onExit sends a bare null. Only `call` carries its own deadline, so
    // without this a dead engine would leave every `eval` — a provider load,
    // most of all — waiting on a reply that can no longer come.
    if (msg == null) {
      if (!_disposed) _fail(JsRuntimeException('JS engine stopped'));
      return;
    }
    if (msg is SendPort) {
      _toIso = msg;
      for (final m in _queued) {
        msg.send(m);
      }
      _queued.clear();
      return;
    }
    // Isolate.spawn's onError delivers [error, stackTrace] as a plain list.
    if (msg is List) {
      debugPrint('[js-isolate] uncaught: ${msg.first}');
      return;
    }
    final m = msg as Map;
    switch (m['t']) {
      case 'boot':
        final err = m['err'];
        if (err == null) {
          if (!_ready.isCompleted) _ready.complete();
        } else {
          _fail(JsRuntimeException('$err'));
        }
      case 'ch':
        _onChannel(m['c'] as String, m['p']);
      case 'res':
        _pending.remove(m['id'])?.complete(
              JsResult(m['v'] as String, isError: m['e'] as bool),
            );
    }
  }

  void _fail(Object e) {
    _dead = e;
    if (!_ready.isCompleted) {
      _ready.completeError(e);
      // Nothing may ever await `ready` — keep the error from going unhandled.
      _ready.future.catchError((_) {});
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    _pending.clear();
    _queued.clear();
  }

  void _send(Map<String, Object?> m) {
    if (_disposed || _dead != null) return;
    final port = _toIso;
    if (port == null) {
      _queued.add(m);
    } else {
      port.send(m);
    }
  }

  Future<JsResult> _request(Map<String, Object?> m) {
    final dead = _dead;
    if (dead != null) return Future.error(dead);
    final id = ++_seq;
    final c = Completer<JsResult>();
    _pending[id] = c;
    _send({...m, 'id': id});
    return c.future;
  }

  @override
  Future<void> get ready => _ready.future;

  @override
  void post(String js) => _send({'op': 'post', 'js': js});

  @override
  Future<JsResult> eval(String js) => _request({'op': 'eval', 'js': js});

  @override
  Future<JsResult> callAsync(String js, Duration timeout) => _request({
        'op': 'call',
        'js': js,
        'ms': timeout.inMilliseconds,
      });

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _send({'op': 'stop'});
    _fromIso.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    // The port is shut; anything still waiting on it never hears back.
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(JsRuntimeException('JS engine closed'));
    }
    _pending.clear();
  }
}
