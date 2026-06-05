import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to the native `zangetsu/external_player` channel: lists installed
/// external video players and hands a resolved stream off to one via an
/// Android `ACTION_VIEW` intent (URL + headers + subtitles + title).
///
/// Android-only — every method is a no-op (returns empty/false) elsewhere.
class ExternalPlayer {
  static const MethodChannel _ch = MethodChannel('zangetsu/external_player');

  /// Installed known players as `(package, label)` rows. Empty on non-Android
  /// or when none are installed.
  Future<List<({String package, String label})>> installed() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('getPlayers');
      return (raw ?? const []).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return (package: '${m['package']}', label: '${m['label']}');
      }).toList();
    } catch (e) {
      // A MissingPluginException here means the native channel isn't in the
      // running build (e.g. native changes applied via hot reload — they need a
      // full reinstall).
      debugPrint('[ExternalPlayer] getPlayers failed: $e');
      return const [];
    }
  }

  /// Launches [url] in the external player [package]. Forwards [headers]
  /// (so header-gated streams work in players that honour them, e.g. MX
  /// Player), [subtitles] (`[{url, name}]`), [title], and a resume [positionMs].
  /// Returns true if the player was launched.
  Future<bool> launch({
    required String url,
    required String package,
    String? title,
    Map<String, String> headers = const {},
    List<Map<String, String>> subtitles = const [],
    int positionMs = 0,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _ch.invokeMethod<bool>('launch', <String, dynamic>{
        'url': url,
        'package': package,
        'title': title,
        'headers': headers,
        'subtitles': subtitles,
        'positionMs': positionMs,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
