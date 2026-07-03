import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Lightweight in-app logger: a capped ring buffer that users can export + share
/// so the developer can debug reported issues. Captures Dart logs/errors only —
/// native crashes (force-close) go to Android logcat, which an app can't read.
/// Secrets (tokens, keys, emails) are redacted before anything is stored.
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int _maxLines = 2000;
  final List<String> _buffer = <String>[];
  File? _file;

  /// Open the on-disk log (best-effort). Safe to skip in tests.
  Future<void> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/zangetsu.log');
      if (await _file!.exists()) {
        final tail = (await _file!.readAsLines());
        _buffer
          ..clear()
          ..addAll(tail.length > _maxLines
              ? tail.sublist(tail.length - _maxLines)
              : tail);
      }
    } catch (_) {
      _file = null;
    }
  }

  void log(String message, {String level = 'I'}) {
    for (final raw in redact(message).split('\n')) {
      _buffer.add('${_stamp()} $level $raw');
    }
    if (_buffer.length > _maxLines) {
      _buffer.removeRange(0, _buffer.length - _maxLines);
    }
    _persist();
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

  @visibleForTesting
  void clearForTest() => _buffer.clear();

  void _persist() {
    final f = _file;
    if (f == null) return;
    // Best-effort async write of the whole (capped) buffer — small + cheap.
    unawaited_(f.writeAsString(_buffer.join('\n')));
  }

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
