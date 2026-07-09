import 'dart:io';

import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

/// Redacts query strings + long tokens so a logged stream URL stays readable
/// and doesn't leak signed credentials. Keeps host + path for diagnosis.
String _safeUrl(String url) {
  final q = url.indexOf('?');
  return q >= 0 ? '${url.substring(0, q)}?…' : url;
}

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
      AppLogger.instance.log('[ext-player] getPlayers failed: $e', level: 'E');
      return const [];
    }
  }

  /// Registers [url] + [headers] with the native localhost proxy and returns a
  /// `http://127.0.0.1/...` URL the external player can play WITHOUT headers
  /// (the proxy injects them upstream). Returns null on non-Android or any
  /// failure, so the caller can fall back to the built-in player.
  Future<String?> proxyStreamUrl(String url, Map<String, String> headers) async {
    if (!Platform.isAndroid) return null;
    try {
      final local = await _ch.invokeMethod<String?>('proxyUrl', <String, dynamic>{
        'url': url,
        'headers': headers,
      });
      AppLogger.instance.log(
        '[ext-player] proxyUrl ${local == null ? "failed (null)" : "ok"} '
        'for ${_safeUrl(url)}',
        level: local == null ? 'E' : 'I',
      );
      return (local != null && local.isNotEmpty) ? local : null;
    } catch (e) {
      AppLogger.instance.log('[ext-player] proxyUrl error: $e', level: 'E');
      return null;
    }
  }

  /// Launches [url] in the external player [package]. Forwards [headers]
  /// (so header-gated streams work in players that honour them, e.g. MX
  /// Player), [subtitles] (`[{url, name}]`), [title], and a resume [positionMs].
  ///
  /// The Future completes when the external player **returns** (closes), with:
  ///  - `launched`: the player started at all (false = not installed / no
  ///    activity → caller should fall back immediately).
  ///  - `played`: the player reported it actually loaded/played the media.
  ///    When false, the player opened but couldn't play it → caller should fall
  ///    back to the built-in player.
  ///  - `positionMs`: watched position reported back (0 if unknown).
  Future<({bool launched, bool played, int positionMs})> launch({
    required String url,
    required String package,
    String? title,
    Map<String, String> headers = const {},
    List<Map<String, String>> subtitles = const [],
    int positionMs = 0,
  }) async {
    if (!Platform.isAndroid) {
      return (launched: false, played: false, positionMs: 0);
    }
    final isHls = url.toLowerCase().contains('.m3u8');
    // Logged so external-player failures are visible in exported logs (they
    // previously used debugPrint, which the log buffer doesn't capture). Header
    // presence matters: header-gated HLS only plays in players that honour the
    // Referer/UA extras (MX Player), and 403s in ones that ignore them (VLC).
    AppLogger.instance.log(
      '[ext-player] launch pkg=${package.isEmpty ? "(chooser)" : package} '
      'hls=$isHls headers=${headers.keys.toList()} subs=${subtitles.length} '
      'url=${_safeUrl(url)}',
    );
    try {
      final res = await _ch.invokeMethod<dynamic>('launch', <String, dynamic>{
        'url': url,
        'package': package,
        'title': title,
        'headers': headers,
        'subtitles': subtitles,
        'positionMs': positionMs,
      });
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      final launched = m['launched'] == true;
      final played = m['played'] == true;
      AppLogger.instance.log(
        '[ext-player] result launched=$launched played=$played '
        'pos=${(m['positionMs'] as num?)?.toInt() ?? 0}'
        '${launched && !played ? " — opened but reported no playback "
            "(header-gated HLS in a player that ignores headers?); "
            "falling back to built-in" : ""}',
        level: launched && !played ? 'E' : 'I',
      );
      return (
        launched: launched,
        played: played,
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      AppLogger.instance.log('[ext-player] launch failed: $e', level: 'E');
      return (launched: false, played: false, positionMs: 0);
    }
  }
}
