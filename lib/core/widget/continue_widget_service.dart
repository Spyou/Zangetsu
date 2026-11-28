import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../playback/watch_history.dart';
import '../privacy/incognito_mode.dart';

/// "Episode 12 · 9 min left" — the widget's second line. Without a known
/// duration there is no time left to show, so it is just the episode.
String continueLine({
  double? number,
  required Duration duration,
  required Duration position,
}) {
  final label = number == null
      ? 'Episode'
      : 'Episode ${number == number.truncate() ? number.toInt() : number}';
  if (duration <= Duration.zero) return label;
  final left = duration - position;
  return '$label · ${left.inMinutes < 1 ? 'under a minute' : '${left.inMinutes} min'} left';
}

/// Keeps the Android home-screen "Continue Watching" widget current.
///
/// The widget only reads what is pushed here (title, episode line, progress,
/// a cover file), so it costs nothing in the background. A push happens a
/// couple of seconds after watch history changes, and when incognito flips;
/// the widget clears when there's nothing to continue or incognito is on.
class ContinueWidgetService {
  ContinueWidgetService._();
  static final instance = ContinueWidgetService._();

  static const _channel = MethodChannel('zangetsu/widget');

  Timer? _debounce;
  String? _lastSent;
  String? _coverUrl;

  Future<void> init() async {
    if (!Platform.isAndroid ||
        (sl.isRegistered<AppMode>() && sl<AppMode>().isTv)) {
      return;
    }
    if (Hive.isBoxOpen(WatchHistory.boxName)) {
      Hive.box<Map>(WatchHistory.boxName).watch().listen((_) => _schedule());
    }
    IncognitoMode.notifier.addListener(_schedule);
    _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => unawaited(_push()));
  }

  Future<void> _push() async {
    try {
      final entry = IncognitoMode.on || !sl.isRegistered<WatchHistory>()
          ? null
          : sl<WatchHistory>().recent(limit: 1).firstOrNull;
      if (entry == null) {
        if (_lastSent == 'clear') return;
        _lastSent = 'clear';
        await _channel.invokeMethod('clear');
        return;
      }
      final sub = continueLine(
        number: entry.episodeNumber,
        duration: entry.duration,
        position: entry.position,
      );
      final cover = await _coverFile(entry.cover, entry.coverHeaders);
      final payload = {
        'title': entry.showTitle,
        'sub': sub,
        'progress': (entry.progress * 100).round(),
        'cover': cover,
        'source': entry.sourceId,
        'show': entry.showId,
      };
      final signature = payload.toString();
      if (signature == _lastSent) return;
      _lastSent = signature;
      await _channel.invokeMethod('update', payload);
    } catch (_) {
      // The widget is a nicety; never let it surface an error.
    }
  }

  /// The cover saved as a small file the widget can read. Re-downloaded only
  /// when the url changes.
  Future<String?> _coverFile(String? url, Map<String, String>? headers) async {
    if (url == null || url.isEmpty) return null;
    final file = File(
      '${(await getApplicationSupportDirectory()).path}/widget_cover.img',
    );
    if (_coverUrl == url && await file.exists()) return file.path;
    try {
      await Dio().download(
        url,
        file.path,
        options: Options(
          headers: headers,
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
        ),
      );
      _coverUrl = url;
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
