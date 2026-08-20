import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

import '../privacy/incognito_mode.dart';
import 'discord_config.dart';
import 'discord_gateway.dart';
import 'discord_presence.dart';
import 'discord_token_store.dart';

/// Orchestrates Discord Rich Presence: holds the Gateway connection, the opt-in
/// toggle, and builds the "watching" / "browsing" presence. Stays connected
/// through Android `paused` (the video player routinely fires that). Clears on
/// player exit, disable, incognito, or process detach.
class DiscordRpc {
  DiscordRpc(this._dio);
  final Dio _dio;

  static const String boxName = 'discord';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  DiscordGateway? _gateway;
  String? _token;
  bool _enabled = false;
  bool _foreground = true;
  DiscordActivity? _current;
  final Map<String, String> _assetCache = {}; // posterUrl -> "mp:..." key
  Timer? _clearTimer;
  Timer? _presenceSendTimer;

  /// Android pauses (and sometimes disposes) the player when the native
  /// surface attaches. Immediate clear would wipe Watching; a short delay
  /// lets the next [setWatching] cancel it.
  static const Duration playerExitClearDelay = Duration(seconds: 2);

  bool get enabled => _enabled;
  bool get loggedIn => _token != null && _token!.isNotEmpty;

  /// Opt-in + credentials. Sending is not gated on Android `paused` — the
  /// player leaves Flutter paused for the whole episode.
  bool get _allowed =>
      _enabled && loggedIn && DiscordConfig.configured && !IncognitoMode.on;

  bool get _canRun => _allowed;

  String get _skipReason {
    if (!DiscordConfig.configured) return 'app id not configured';
    if (!loggedIn) return 'not logged in';
    if (!_enabled) return 'rich presence toggle off';
    if (IncognitoMode.on) return 'incognito';
    return 'ok';
  }

  /// Load persisted state + connect if everything's ready. Call at startup.
  Future<void> start() async {
    _enabled = _box.get('enabled', defaultValue: false) as bool;
    _token = await DiscordTokenStore.read();
    // Incognito pauses presence: flipping it on drops the connection, off resumes.
    IncognitoMode.notifier.addListener(_onIncognitoChanged);
    debugPrint(
      '[discord] start enabled=$_enabled loggedIn=$loggedIn '
      'configured=${DiscordConfig.configured} incognito=${IncognitoMode.on} '
      'foreground=$_foreground → $_skipReason',
    );
    if (_canRun) _connect();
  }

  void _onIncognitoChanged() {
    debugPrint('[discord] incognito=${IncognitoMode.on}');
    if (_canRun) {
      _connect();
    } else {
      unawaited(_disconnect());
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _box.put('enabled', value);
    debugPrint('[discord] setEnabled $value');
    if (_canRun) {
      _connect();
    } else {
      if (!value) _current = null;
      unawaited(_disconnect());
    }
  }

  /// Save (or clear, with null) the captured Discord user token.
  Future<void> setToken(String? token) async {
    _token = token;
    if (!loggedIn) {
      await DiscordTokenStore.clear();
      _current = null;
      debugPrint('[discord] token cleared');
      unawaited(_disconnect());
    } else {
      await DiscordTokenStore.write(token!);
      debugPrint('[discord] discord login stored (${token.length} chars)');
      if (_canRun) _connect();
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  void onForeground() {
    _foreground = true;
    debugPrint('[discord] foreground');
    if (_canRun) _connect();
  }

  /// Flutter `paused` — keep the gateway. Native video surfaces trigger this
  /// for the entire playback session; clearing here made Watching vanish.
  void onPaused() {
    debugPrint('[discord] lifecycle paused — keeping gateway + presence');
  }

  /// Process is going away — flush an empty activity so the profile drops.
  void onDetached() {
    _foreground = false;
    debugPrint('[discord] detached — clearing presence + disconnect');
    unawaited(_disconnect());
  }

  // ── Presence ──────────────────────────────────────────────────────────────
  Future<void> setWatching({
    required String title,
    String? episodeLabel,
    String? posterUrl,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool playing = true,
  }) async {
    if (!_allowed) {
      debugPrint('[discord] setWatching skipped ($_skipReason) title=$title');
      return;
    }
    _cancelScheduledClear();
    final ts = discordPlaybackTimestamps(
      position: position,
      duration: duration,
      playing: playing,
    );
    final large = posterUrl != null ? await _externalAsset(posterUrl) : null;
    final logo = await _appLogoKey();
    _current = DiscordActivity(
      name: title,
      type: 3, // Watching
      details: episodeLabel,
      state: 'on ${DiscordConfig.appName}',
      largeImage: large ?? logo,
      largeText: title,
      smallImage: large != null ? logo : null,
      smallText: 'Watching on ${DiscordConfig.appName}',
      startMs: ts.startMs,
      endMs: ts.endMs,
    );
    debugPrint(
      '[discord] setWatching "$title" ${episodeLabel ?? ''} '
      'playing=$playing pos=${position.inSeconds}s dur=${duration.inSeconds}s '
      'bar=${ts.startMs != null && ts.endMs != null}'
      '${duration <= Duration.zero ? " (end=null until duration known)" : ""} '
      'gateway=${_gateway != null} readySend=$_canRun',
    );
    if (_canRun) {
      _queuePresenceSend();
    } else {
      debugPrint('[discord] setWatching held, not sent ($_skipReason)');
    }
  }

  Future<void> setBrowsing({String? title, String? posterUrl}) async {
    if (!_allowed) {
      debugPrint('[discord] setBrowsing skipped ($_skipReason)');
      return;
    }
    _cancelScheduledClear();
    final large = posterUrl != null ? await _externalAsset(posterUrl) : null;
    final logo = await _appLogoKey();
    _current = DiscordActivity(
      name: DiscordConfig.appName,
      type: 0, // Playing → "Playing Zangetsu"
      details: title != null ? 'Looking at $title' : 'Browsing',
      largeImage: large ?? logo,
      largeText: title ?? DiscordConfig.appName,
      smallImage: large != null ? logo : null,
    );
    debugPrint(
      '[discord] setBrowsing ${title ?? "(app)"} image=${_current!.largeImage} '
      'gateway=${_gateway != null} send=$_canRun',
    );
    if (_canRun) {
      _queuePresenceSend();
    } else {
      debugPrint('[discord] setBrowsing held, not sent ($_skipReason)');
    }
  }

  /// Discord drops status updates that arrive too close together. A Watching
  /// line with no duration (end=null) followed ~1s later by the real bar would
  /// leave the profile stuck without a progress bar.
  void _queuePresenceSend() {
    _presenceSendTimer?.cancel();
    _presenceSendTimer = Timer(const Duration(milliseconds: 400), () {
      if (_canRun) _gateway?.setPresence(_current);
    });
  }

  /// Drop the current activity. [delay] is for player teardown: Android
  /// disposes the player on `paused`, then immediately rebuilds it — a new
  /// [setWatching] cancels the timer so Watching survives. A real exit
  /// (no follow-up presence) still clears after the delay.
  void clear({Duration delay = Duration.zero}) {
    _clearTimer?.cancel();
    if (delay <= Duration.zero) {
      _applyClear();
      return;
    }
    debugPrint('[discord] clear scheduled in ${delay.inMilliseconds}ms');
    _clearTimer = Timer(delay, _applyClear);
  }

  void _cancelScheduledClear() {
    if (_clearTimer == null) return;
    debugPrint('[discord] clear cancelled (new presence)');
    _clearTimer!.cancel();
    _clearTimer = null;
  }

  void _applyClear() {
    _clearTimer = null;
    _presenceSendTimer?.cancel();
    _presenceSendTimer = null;
    debugPrint('[discord] clear presence gateway=${_gateway != null}');
    _current = null;
    _gateway?.setPresence(null);
  }

  // ── Internals ───────────────────────────────────────────────────────────
  void _connect() {
    if (_gateway != null) {
      debugPrint('[discord] already connected — re-push current=${_current?.name}');
      if (_current != null) {
        _presenceSendTimer?.cancel();
        _gateway!.setPresence(_current);
      }
      return;
    }
    debugPrint('[discord] connecting gateway');
    _gateway = DiscordGateway(_token!)..connect();
    if (_current != null) _gateway!.setPresence(_current);
  }

  Future<void> _disconnect() async {
    final g = _gateway;
    _gateway = null;
    if (g == null) return;
    _cancelScheduledClear();
    _presenceSendTimer?.cancel();
    _presenceSendTimer = null;
    debugPrint('[discord] disconnect (flush clear first)');
    await g.clearThenClose();
  }

  /// App logo as a Discord-displayable image key (proxied URL, not the
  /// named `logo` portal asset — that one isn't uploaded, so Discord shows ?).
  Future<String> _appLogoKey() async {
    final key = await _externalAsset(DiscordConfig.appLogoUrl);
    return key ?? DiscordConfig.appLogoUrl;
  }

  /// Convert a poster URL into a Discord-displayable `mp:external/...` key via
  /// the external-assets API (so the real cover shows). Cached per URL.
  Future<String?> _externalAsset(String url) async {
    final cached = _assetCache[url];
    if (cached != null) return cached;
    if (!loggedIn || !DiscordConfig.configured) return null;
    try {
      final r = await _dio.post<dynamic>(
        '${DiscordConfig.api}/applications/${DiscordConfig.applicationId}/external-assets',
        data: {
          'urls': [url],
        },
        options: Options(headers: {'Authorization': _token}),
      );
      final list = r.data as List<dynamic>;
      final path = (list.first as Map)['external_asset_path'] as String;
      final key = 'mp:$path';
      _assetCache[url] = key;
      return key;
    } catch (e) {
      debugPrint('[discord] external asset failed: $e');
      return null; // fall back to the app logo
    }
  }
}
