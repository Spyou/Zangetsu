import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/app_paths.dart';

/// Lightweight in-app logger: a capped ring buffer that users can export + share
/// so the developer can debug reported issues. Captures Dart logs/errors only —
/// native crashes (force-close) go to Android logcat, which an app can't read.
/// Secrets (tokens, keys, emails) are redacted before anything is stored.
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int _maxLines = 2000;

  /// Lines appended since the file was last written out in full. Past this the
  /// file is rewritten from the (capped) buffer, which is what keeps it from
  /// growing forever — see [_persist].
  static const int _compactEvery = 2000;

  final List<String> _buffer = <String>[];
  File? _file;
  int _appended = 0;

  /// How many times the whole file has been rewritten. The point of the change
  /// is that this stays tiny while lines keep arriving, so it is the only
  /// thing a test can assert to tell the fix apart from what it replaced.
  @visibleForTesting
  int compactions = 0;

  /// Open the on-disk log (best-effort). Safe to skip in tests.
  Future<void> init() async {
    try {
      final dir = await getWritableAppDirectory();
      await _openAt(File('${dir.path}/zangetsu.log'));
    } catch (_) {
      _file = null;
    }
  }

  /// [init] against an explicit file, so tests don't need path_provider.
  @visibleForTesting
  Future<void> initAt(File f) => _openAt(f);

  Future<void> _openAt(File f) async {
    _file = f;
    _appended = 0;
    if (await f.exists()) {
      final tail = await f.readAsLines();
      _buffer
        ..clear()
        ..addAll(tail.length > _maxLines
            ? tail.sublist(tail.length - _maxLines)
            : tail);
    }
  }

  void log(String message, {String level = 'I'}) {
    final fresh = <String>[];
    for (final raw in redact(message).split('\n')) {
      final line = '${_stamp()} $level $raw';
      fresh.add(line);
      _buffer.add(line);
      // Errors also go to the console. Until now they went ONLY here, so a
      // failure like "download resolve failed" was invisible to logcat and
      // could only be read by exporting the log from inside the app — which
      // is no help when the app is the thing misbehaving. Already redacted.
      if (level == 'E') debugPrint('[app] $raw');
    }
    if (_buffer.length > _maxLines) {
      _buffer.removeRange(0, _buffer.length - _maxLines);
    }
    _persist(fresh);
  }

  void logError(Object error, StackTrace? stack) {
    log('$error', level: 'E');
    if (stack != null) {
      log(stack.toString().split('\n').take(12).join('\n'), level: 'E');
    }
  }

  String get contents => _buffer.join('\n');

  /// Write the current buffer to a shareable temp file; returns null on failure.
  Future<File?> exportFile() async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/zangetsu-logs.txt');
      await f.writeAsString('Zangetsu logs\n\n$contents\n');
      return f;
    } catch (_) {
      return null;
    }
  }

  /// Resets everything, including the file handle — the logger is a singleton,
  /// so a test that attached a file would otherwise leak it into the next one.
  @visibleForTesting
  void clearForTest() {
    _buffer.clear();
    _file = null;
    _appended = 0;
    compactions = 0;
    _writes = Future<void>.value();
  }

  /// Appends [fresh] to the file, rewriting it in full only every
  /// [_compactEvery] lines.
  ///
  /// It used to join the WHOLE buffer and rewrite the whole file on every
  /// single log line. Every `debugPrint` in the app routes through here
  /// (main.dart wraps it), so one source sweep — hundreds of lines — meant
  /// hundreds of 2000-line string joins on the UI isolate and hundreds of
  /// whole-file writes.
  ///
  /// Appending is deliberate rather than debouncing: this log exists to
  /// explain a crash, and a crash takes the process with it. A debounce would
  /// drop exactly the last lines, which are the ones worth having.
  void _persist(List<String> fresh) {
    final f = _file;
    if (f == null || fresh.isEmpty) return;
    _appended += fresh.length;
    if (_appended >= _compactEvery) {
      _appended = 0;
      compactions++;
      _queue(() => f.writeAsString('${_buffer.join('\n')}\n'));
      return;
    }
    _queue(
      () => f.writeAsString('${fresh.join('\n')}\n', mode: FileMode.append),
    );
  }

  /// Writes run strictly one after another. Two overlapping `writeAsString`
  /// calls on the same file can interleave, and an append landing inside a
  /// compaction would corrupt the log we are trying to read later.
  Future<void> _writes = Future<void>.value();

  void _queue(Future<void> Function() op) {
    _writes = _writes.then((_) => op()).catchError((_) {});
  }

  /// Lets a test (or a shutdown path) wait for queued writes to land.
  @visibleForTesting
  Future<void> flush() => _writes;

  static void unawaited_(Future<void> f) {
    f.catchError((_) {});
  }

  static String _stamp() {
    final n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(n.hour)}:${p(n.minute)}:${p(n.second)}.${p(n.millisecond, 3)}';
  }

  /// Strip secrets so a shared log never leaks a session/token/key/email.
  @visibleForTesting
  static String redact(String s) {
    var out = s;
    out = out.replaceAll(
        RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'), '<email>');
    out = out.replaceAll(RegExp(r'\bstandard_[A-Fa-f0-9]{16,}\b'), '<key>');
    out = out.replaceAll(
        RegExp(r'\bey[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}'),
        '<jwt>');
    out = out.replaceAllMapped(
      RegExp(
        r'\b(authorization|bearer|token|password|passwd|session|api[_-]?key)\b(["\s:=]+)(\S+)',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}<redacted>',
    );
    return out;
  }
}
