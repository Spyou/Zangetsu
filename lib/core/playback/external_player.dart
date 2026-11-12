import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../torrent/torrent_util.dart';
import 'playback_prefs.dart';

/// Redacts query strings + long tokens so a logged stream URL stays readable
/// and doesn't leak signed credentials. Keeps host + path for diagnosis.
String _safeUrl(String url) {
  final q = url.indexOf('?');
  return q >= 0 ? '${url.substring(0, q)}?…' : url;
}

/// External players that forward HTTP request headers (Referer/Origin/Cookie)
/// to the stream. Players NOT on this list (VLC, SPlayer, LeePlayer, …) ignore
/// them, so a header-gated source 403s — callers hand those the local
/// header-injecting proxy URL instead. Prefix-matched to cover package
/// variants (e.g. MX Player free `.ad` + `.pro`).
const List<String> kHeaderForwardingPlayers = [
  'com.mxtech.videoplayer', // MX Player (free .ad + pro)
  'com.brouken.player', // Just Player
];

/// True when [headers] carry a gating header (Referer/Origin/Cookie) that the
/// chosen external player [pkg] cannot forward — so the stream would 403
/// without a proxy. Pure so it is unit-testable.
@visibleForTesting
bool headerGatedButPlayerCant(Map<String, String>? headers, String pkg) {
  if (headers == null || headers.isEmpty || pkg.isEmpty) return false;
  final gated = headers.keys.any((k) {
    final lk = k.toLowerCase();
    return lk == 'referer' || lk == 'origin' || lk == 'cookie';
  });
  if (!gated) return false;
  return !kHeaderForwardingPlayers.any(pkg.startsWith);
}

/// True when [url] is already served by a local proxy (localhost / 127.0.0.1) —
/// e.g. a CloudStream extractor's own proxy. Kept for tests / diagnostics;
/// hand-off still routes these through our proxy when headers are gated.
@visibleForTesting
bool isLocalStreamUrl(String url) {
  final u = url.toLowerCase();
  return u.startsWith('http://localhost') ||
      u.startsWith('http://127.0.0.1') ||
      u.startsWith('https://localhost') ||
      u.startsWith('https://127.0.0.1');
}

/// True when [url] is an MPEG-DASH manifest (`.mpd`, ignoring any query string).
/// External players can't reliably play header-gated DASH and our proxy only
/// rewrites HLS, so these route to the built-in player.
@visibleForTesting
bool isDashUrl(String url) =>
    url.toLowerCase().split('?').first.endsWith('.mpd');

/// How a resolved stream should be handed to [package].
enum ExternalHandoff {
  /// Play in the built-in player (torrent, header-gated DASH, …).
  builtIn,

  /// Pass [url] + headers straight to the external player.
  direct,

  /// Register with the localhost proxy and pass that URL (no intent headers).
  proxy,
}

/// Decides whether [url]/[headers] can go to [package], and whether the
/// local header-injecting proxy is required. Shared by phone + TV hand-off.
ExternalHandoff externalHandoffFor({
  required String url,
  required Map<String, String>? headers,
  required String package,
}) {
  if (isTorrentUrl(url)) return ExternalHandoff.builtIn;
  if (!headerGatedButPlayerCant(headers, package)) {
    return ExternalHandoff.direct;
  }
  if (isDashUrl(url)) return ExternalHandoff.builtIn;
  return ExternalHandoff.proxy;
}

/// True when [package] is a real third-party player package (not empty built-in
/// and not the in-app Android Exo id).
bool isExternalPlayerPackage(String package) =>
    package.isNotEmpty && package != PlaybackPrefs.androidPlayerId;

/// Bridge to the native `zangetsu/external_player` channel: lists installed
/// external video players and hands a resolved stream off to one via an
/// Android `ACTION_VIEW` intent (URL + headers + subtitles + title).
///
/// Android-only — every method is a no-op (returns empty/false) elsewhere.
class ExternalPlayer {
  static const MethodChannel _ch = MethodChannel('zangetsu/external_player');

  /// Installed video players as `(package, label, known)` rows, empty on
  /// non-Android.
  ///
  /// Ordered known-first: `known` players are the ones whose intent extras we
  /// know, so subtitles and the resume position reach them. The rest are
  /// whatever else on the device answers an `ACTION_VIEW` video intent — real
  /// players we've never heard of, but also galleries and browsers. Those still
  /// play (header-gated streams included — anything outside
  /// `kHeaderForwardingPlayers` is handed the local header-injecting proxy URL),
  /// they just may ignore the subtitle and position extras. Callers should
  /// present them under their own heading rather than mixed in.
  Future<List<({String package, String label, bool known})>> installed() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('getPlayers');
      return (raw ?? const []).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return (
          package: '${m['package']}',
          label: '${m['label']}',
          // Absent on an older native build that predates the flag — treating
          // those as known keeps the previous behaviour instead of dumping the
          // whole list under "Other apps".
          known: m['known'] != '0',
        );
      }).toList();
    } catch (e) {
      // A MissingPluginException here means the native channel isn't in the
      // running build (e.g. native changes applied via hot reload — they need a
      // full reinstall).
      AppLogger.instance.log('[ext-player] getPlayers failed: $e', level: 'E');
      return const [];
    }
  }

  /// Registers [url] + [headers] with the native stream proxy and returns a
  /// URL the external player can play WITHOUT headers (the proxy injects them
  /// upstream). Advertises the phone's LAN IP when available so a Cast
  /// receiver (Shield / Chromecast) can fetch it; otherwise `127.0.0.1`.
  /// Returns null on non-Android or any failure, so the caller can fall back
  /// to the built-in player.
  Future<String?> proxyStreamUrl(
    String url,
    Map<String, String> headers,
  ) async {
    if (!Platform.isAndroid) return null;
    try {
      final local = await _ch.invokeMethod<String?>(
        'proxyUrl',
        <String, dynamic>{'url': url, 'headers': headers},
      );
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
      final resultCode = (m['resultCode'] as num?)?.toInt();
      // `played` is not a failure signal and never has been: VLC and friends
      // hand playback to their own task and return immediately, so a perfectly
      // healthy launch reports played=false. The caller keys off `launched`
      // alone — see PlayerScreen's launch handler, which leaves this screen on
      // launched=true and only opens the built-in player when the launch
      // itself failed. Logged at info for that reason; this line used to claim
      // a fallback that the code doesn't do, and reading it as gospel sent a
      // debugging session hunting through fallback logic while the real fault
      // was upstream of the player entirely.
      AppLogger.instance.log(
        '[ext-player] result launched=$launched played=$played '
        'pos=${(m['positionMs'] as num?)?.toInt() ?? 0}'
        '${resultCode != null ? " resultCode=$resultCode" : ""}'
        '${launched && !played ? " — handed off; the player reports no "
                  "progress of its own, which is normal" : ""}',
        level: launched ? 'I' : 'E',
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
