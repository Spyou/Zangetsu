import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

import '../platform/apple_tv.dart';
import '../privacy/incognito_mode.dart';
import 'discord_auth.dart';
import 'discord_config.dart';
import 'discord_gateway.dart';
import 'discord_sdk_gateway.dart';
import 'discord_presence.dart';
import 'discord_token_store.dart';

/// Orchestrates Discord Rich Presence: holds the Gateway connection, the opt-in
/// toggle, and builds the "watching" / "browsing" presence. Stays connected
/// through Android `paused` (the video player routinely fires that). Clears on
/// player exit, disable, incognito, or process detach.
///
/// Login is OAuth2 + PKCE in the external browser (same pattern as the MAL
/// tracker): no client secret, short-lived access token with a stored refresh
/// token, profile from /users/@me. The old WebView token scraper is gone —
/// scraping a user token breaks whenever Discord renames a webpack chunk, and
/// user tokens are one ToS complaint away from a banned account.
class DiscordRpc {
  DiscordRpc(this._dio);
  final Dio _dio;

  static const String boxName = 'discord';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Completer<bool>? _pendingAuth;
  bool _handlingRedirect = false;

  /// Last OAuth failure, human-readable for the settings screen to show.
  /// Null means "no error info" (e.g. the browser never came back).
  String? lastAuthError;

  DiscordGateway? _gateway;
  String? _accessToken;
  bool _enabled = false;
  bool _foreground = true;
  DiscordActivity? _current;
  int _presenceRevision = 0;
  final Map<String, String> _assetCache = {}; // posterUrl -> "mp:..." key
  Timer? _clearTimer;
  Timer? _presenceSendTimer;

  /// Android pauses (and sometimes disposes) the player when the native
  /// surface attaches. Immediate clear would wipe Watching; a short delay
  /// lets the next [setWatching] cancel it.
  static const Duration playerExitClearDelay = Duration(seconds: 2);

  bool get enabled => _enabled;
  bool get loggedIn => _accessToken != null && _accessToken!.isNotEmpty;

  /// Account profile from /users/@me (username, display name, avatar).
  String get username => _box.get('username', defaultValue: '') as String;
  String get displayName => _box.get('displayName', defaultValue: '') as String;
  String get avatarUrl => _box.get('avatarUrl', defaultValue: '') as String;

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
  /// Also retires any WebView-scraped user token left in secure storage: the
  /// OAuth session (Hive box) is the only credential now, and a leftover raw
  /// token must never silently keep self-botting.
  Future<void> start() async {
    _enabled = _box.get('enabled', defaultValue: false) as bool;
    _accessToken = _box.get('accessToken') as String?;
    await DiscordTokenStore.clear();
    // Incognito pauses presence: flipping it on drops the connection, off resumes.
    IncognitoMode.notifier.addListener(_onIncognitoChanged);
    debugPrint(
      '[discord] start enabled=$_enabled loggedIn=$loggedIn '
      'configured=${DiscordConfig.configured} incognito=${IncognitoMode.on} '
      'foreground=$_foreground → $_skipReason',
    );
    if (_canRun) unawaited(_connect());
  }

  void _onIncognitoChanged() {
    debugPrint('[discord] incognito=${IncognitoMode.on}');
    if (_canRun) {
      unawaited(_connect());
    } else {
      unawaited(_disconnect());
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _box.put('enabled', value);
    debugPrint('[discord] setEnabled $value');
    if (_canRun) {
      unawaited(_connect());
    } else {
      if (!value) _current = null;
      unawaited(_disconnect());
    }
  }

  // ── OAuth login ─────────────────────────────────────────────────────────
  // Browser flow (external application, never a WebView): the
  // discord-<appId>:/authorize/callback redirect comes back through the
  // manifest intent-filter into [_onLink], like the tracker OAuth logins.

  void _ensureLinkListener() {
    if (_linkSub != null || isAppleTv) return;
    _linkSub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    _appLinks
        .getInitialLink()
        .then((u) {
          if (u != null) _onLink(u);
        })
        .catchError((_) {});
  }

  String _random(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Launch that never throws: some resolvers raise instead of returning
  /// false when nothing handles the URL.
  Future<bool> _tryLaunch(Uri url, LaunchMode mode) async {
    try {
      return await launchUrl(url, mode: mode);
    } catch (e) {
      debugPrint('[discord] launch ($mode) threw: $e');
      return false;
    }
  }

  /// Browser OAuth login. True when the session (tokens + profile) is stored.
  /// On false, [lastAuthError] says why (redirect mismatch, denied, timeout).
  Future<bool> connect() async {
    final active = _pendingAuth;
    if (active != null) return active.future;
    final pending = Completer<bool>();
    _pendingAuth = pending;
    lastAuthError = null;
    try {
      _ensureLinkListener();
      final verifier = _random(64);
      final state = _random(32);
      await _box.put('codeVerifier', verifier);
      await _box.put('oauthState', state);
      final url = DiscordAuth.authorizeUri(
        applicationId: DiscordConfig.applicationId,
        state: state,
        challenge: DiscordAuth.codeChallenge(verifier),
      );
      // Discord's Android app handles its action URI, not the web OAuth path.
      var opened = false;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        opened = await _tryLaunch(
          DiscordAuth.nativeAuthorizeUri(url),
          LaunchMode.externalApplication,
        ).timeout(const Duration(seconds: 10), onTimeout: () => false);
      }
      opened =
          opened ||
          await _tryLaunch(
            url,
            LaunchMode.externalApplication,
          ).timeout(const Duration(seconds: 10), onTimeout: () => false);
      if (!opened) {
        lastAuthError = 'Could not open Discord or the browser.';
        return false;
      }
      // The redirect can arrive before launchUrl finishes; retain this future.
      return await pending.future.timeout(const Duration(minutes: 3));
    } on TimeoutException {
      lastAuthError = 'Discord login timed out. Please try connecting again.';
      return false;
    } catch (_) {
      lastAuthError ??= 'Could not start Discord login. Please try again.';
      return false;
    } finally {
      if (identical(_pendingAuth, pending)) {
        await _box.delete('codeVerifier');
        await _box.delete('oauthState');
        _pendingAuth = null;
      }
      if (!pending.isCompleted) pending.complete(false);
    }
  }

  void _onLink(Uri uri) {
    if (!DiscordAuth.isCallback(uri, DiscordConfig.applicationId)) return;
    unawaited(_handleRedirect(uri));
  }

  Future<void> _handleRedirect(Uri uri) async {
    // Ignore unrelated/stale links without cancelling the current login.
    final state = uri.queryParameters['state'];
    final saved = _box.get('oauthState') as String?;
    if (_handlingRedirect || state == null || saved == null || state != saved) {
      return;
    }
    _handlingRedirect = true;
    final pending = _pendingAuth;
    var ok = false;
    try {
      final error = uri.queryParameters['error'];
      if (error != null) {
        throw StateError(uri.queryParameters['error_description'] ?? error);
      }
      final code = uri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw StateError('No authorization code received.');
      }
      final verifier = _box.get('codeVerifier') as String?;
      if (verifier == null || verifier.isEmpty) {
        throw StateError('Login expired. Please try again.');
      }
      ok = await _exchangeCode(code, verifier);
      if (!ok) {
        lastAuthError ??= 'Discord could not complete login. Please try again.';
      }
    } catch (e) {
      lastAuthError = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      _handlingRedirect = false;
      if (pending != null && !pending.isCompleted) pending.complete(ok);
    }
  }

  Future<bool> _exchangeCode(String code, String verifier) async {
    try {
      final res = await _dio.post<dynamic>(
        DiscordAuth.tokenEndpoint,
        data: {
          'client_id': DiscordConfig.applicationId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': DiscordAuth.redirectUri(DiscordConfig.applicationId),
          'code_verifier': verifier,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is! Map || d['access_token'] == null) {
        final error = d is Map ? d['error'] : null;
        lastAuthError = error == 'invalid_client'
            ? 'Discord app setup is incomplete. Enable Public Client in its OAuth2 settings.'
            : 'Discord could not complete login (HTTP ${res.statusCode}${error == null ? '' : ': $error'}).';
        return false;
      }
      await _storeSession(d);
      await _fetchAccount();
      _accessToken = _box.get('accessToken') as String?;
      debugPrint('[discord] oauth login stored');
      if (_canRun) unawaited(_connect());
      return true;
    } catch (e) {
      debugPrint('[discord] code exchange failed: $e');
      return false;
    }
  }

  Future<void> _storeSession(Map<dynamic, dynamic> d) async {
    await _box.put('accessToken', '${d['access_token']}');
    final refresh = d['refresh_token'];
    if (refresh != null && '$refresh'.isNotEmpty) {
      await _box.put('refreshToken', '$refresh');
    }
    final expiresIn = (d['expires_in'] as num?)?.toInt() ?? 0;
    await _box.put(
      'expiresAt',
      expiresIn > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
          : 0,
    );
  }

  /// A valid access token, refreshing first when it expires within 60s. This
  /// is what makes login survive: Discord access tokens live ~7 days, and the
  /// user never sees a re-login unless the refresh token itself dies.
  Future<String?> getValidAccessToken() async {
    var token = _accessToken ?? _box.get('accessToken') as String?;
    if (token == null || token.isEmpty) return null;
    final exp = (_box.get('expiresAt') as int?) ?? 0;
    if (exp == 0 || DateTime.now().millisecondsSinceEpoch < exp - 60000) {
      _accessToken = token;
      return token;
    }
    return _refreshNow();
  }

  /// Force a refresh (gateway invalid-session, or expiry). Null when the
  /// session is dead — the caller logs out and the settings show login again.
  Future<String?> _refreshNow() async {
    final refresh = _box.get('refreshToken') as String?;
    if (refresh == null || refresh.isEmpty) return null;
    try {
      final res = await _dio.post<dynamic>(
        DiscordAuth.tokenEndpoint,
        data: {
          'client_id': DiscordConfig.applicationId,
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is! Map || d['access_token'] == null) return null;
      await _storeSession(d);
      _accessToken = _box.get('accessToken') as String?;
      debugPrint('[discord] token refreshed');
      return _accessToken;
    } catch (e) {
      debugPrint('[discord] refresh failed: $e');
      return null;
    }
  }

  Future<void> _fetchAccount() async {
    final token = _box.get('accessToken') as String?;
    if (token == null || token.isEmpty) return;
    try {
      final res = await _dio.get<dynamic>(
        DiscordAuth.meEndpoint,
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is! Map) return;
      final id = '${d['id'] ?? ''}';
      final username = '${d['username'] ?? ''}';
      final display = '${d['global_name'] ?? d['username'] ?? ''}';
      await _box.put('username', username);
      await _box.put('displayName', display);
      await _box.put(
        'avatarUrl',
        DiscordAuth.avatarUrl(id, d['avatar'] as String?) ?? '',
      );
    } catch (e) {
      debugPrint('[discord] profile fetch failed: $e');
    }
  }

  /// Log out: drop the session + tokens and disconnect. The account is
  /// untouched — reconnecting is one browser tap.
  Future<void> logout() async {
    await setEnabled(false);
    for (final k in const [
      'accessToken',
      'refreshToken',
      'expiresAt',
      'username',
      'displayName',
      'avatarUrl',
    ]) {
      await _box.delete(k);
    }
    _accessToken = null;
    _current = null;
    debugPrint('[discord] logged out');
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  void onForeground() {
    _foreground = true;
    debugPrint('[discord] foreground');
    if (_canRun) unawaited(_connect());
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
  // Text sources ('app' | 'title' | 'episode') and image choices mirror
  // ArchiveTune's Discord screen, adapted to shows: Name/Details/State each
  // pick what they render. Defaults reproduce the historical lines exactly.

  String get nameSrc => _box.get('nameSrc', defaultValue: 'title') as String;
  String get detailsSrc =>
      _box.get('detailsSrc', defaultValue: 'episode') as String;
  String get stateSrc => _box.get('stateSrc', defaultValue: 'app') as String;
  String get presenceStatus =>
      _box.get('presenceStatus', defaultValue: 'online') as String;
  String get largeImageSrc =>
      _box.get('largeImage', defaultValue: 'poster') as String;
  String get smallImageSrc =>
      _box.get('smallImage', defaultValue: 'logo') as String;
  bool get showPresenceButton =>
      _box.get('showButton', defaultValue: true) as bool;
  String get presenceButtonLabel =>
      _box.get('buttonLabel', defaultValue: '') as String;
  bool get showWhenPaused => _box.get('showPaused', defaultValue: true) as bool;
  bool get browsingShowsTitle =>
      _box.get('browsingTitle', defaultValue: true) as bool;

  Future<void> setPresencePref(String key, Object value) async {
    await _box.put(key, value);
  }

  Future<void> setWatching({
    required String title,
    String? episodeLabel,
    String? posterUrl,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool playing = true,
    // https open link for the "Open in Zangetsu" button (ShareLink.watchUrl).
    // Null omits the button — same payload as before.
    String? openUrl,
  }) async {
    if (!_allowed) {
      return;
    }
    if (!playing && !showWhenPaused) {
      clear();
      return;
    }
    _cancelScheduledClear();
    final revision = ++_presenceRevision;
    final ts = discordPlaybackTimestamps(
      position: position,
      duration: duration,
      playing: playing,
    );
    final large = await _resolveLarge(posterUrl);
    final logo = await _appLogoKey();
    if (revision != _presenceRevision || !_allowed) return;
    final details = (episodeLabel == null && detailsSrc == 'episode')
        ? null
        : discordSourceLine(
            detailsSrc,
            title: title,
            episode: episodeLabel,
            appText: DiscordConfig.appName,
          );
    var buttonLabel = presenceButtonLabel;
    if (buttonLabel.isEmpty) buttonLabel = 'Open in Zangetsu';
    _current = DiscordActivity(
      name: discordSourceLine(
        nameSrc,
        title: title,
        episode: episodeLabel,
        appText: DiscordConfig.appName,
      ),
      type: 3, // Watching
      details: details,
      state: discordSourceLine(
        stateSrc,
        title: title,
        episode: episodeLabel,
        appText: 'on ${DiscordConfig.appName}',
      ),
      largeImage: large,
      largeText: title,
      smallImage: smallImageSrc == 'logo' && large != null ? logo : null,
      smallText: 'Watching on ${DiscordConfig.appName}',
      startMs: ts.startMs,
      endMs: ts.endMs,
      buttons: showPresenceButton && openUrl != null
          ? [(label: buttonLabel, url: openUrl)]
          : const [],
    );
    debugPrint(
      '[discord] setWatching "$title" ${episodeLabel ?? ''} '
      'playing=$playing pos=${position.inSeconds}s dur=${duration.inSeconds}s '
      'bar=${ts.startMs != null && ts.endMs != null}'
      '${duration <= Duration.zero ? " (end=null until duration known)" : ""} '
      'openUrl=${openUrl != null} '
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
    final revision = ++_presenceRevision;
    final large = await _resolveLarge(posterUrl);
    final logo = await _appLogoKey();
    if (revision != _presenceRevision || !_allowed) return;
    _current = DiscordActivity(
      name: DiscordConfig.appName,
      type: 0, // Playing → "Playing Zangetsu"
      details: (browsingShowsTitle && title != null)
          ? 'Looking at $title'
          : 'Browsing',
      largeImage: large,
      largeText: title ?? DiscordConfig.appName,
      smallImage: smallImageSrc == 'logo' && large != null ? logo : null,
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
      if (_canRun) _gateway?.setPresence(_current, status: presenceStatus);
    });
  }

  /// Drop the current activity. [delay] is for player teardown: Android
  /// disposes the player on `paused`, then immediately rebuilds it — a new
  /// [setWatching] cancels the timer so Watching survives. A real exit
  /// (no follow-up presence) still clears after the delay.
  void clear({Duration delay = Duration.zero}) {
    _presenceRevision++;
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
    _gateway?.setPresence(null, status: presenceStatus);
  }

  // ── Internals ───────────────────────────────────────────────────────────
  Future<void> _connect() async {
    if (_gateway != null) {
      debugPrint(
        '[discord] already connected — re-push current=${_current?.name}',
      );
      if (_current != null) {
        _presenceSendTimer?.cancel();
        _gateway!.setPresence(_current, status: presenceStatus);
      }
      return;
    }
    final token = await getValidAccessToken();
    if (token == null || token.isEmpty) {
      debugPrint('[discord] connect skipped (no valid token)');
      return;
    }
    debugPrint('[discord] connecting gateway');
    _gateway =
        (supportsNativeDiscordPresence
              ? DiscordSdkGateway(token, onAuthFailure: _onAuthFailure)
              : DiscordGateway('Bearer $token', onAuthFailure: _onAuthFailure))
          ..connect();
    if (_current != null) {
      _gateway!.setPresence(_current, status: presenceStatus);
    }
  }

  /// Gateway rejected the session (op 9): refresh once and resume on the same
  /// socket; a dead refresh token means logout and the settings show login.
  Future<void> _onAuthFailure() async {
    debugPrint('[discord] session rejected — refreshing');
    final token = await _refreshNow();
    if (token == null || token.isEmpty) {
      debugPrint('[discord] refresh dead — logging out');
      await logout();
      return;
    }
    _gateway?.updateToken('Bearer $token');
  }

  Future<void> _disconnect() async {
    _presenceRevision++;
    final g = _gateway;
    _gateway = null;
    if (g == null) return;
    _cancelScheduledClear();
    _presenceSendTimer?.cancel();
    _presenceSendTimer = null;
    debugPrint('[discord] disconnect (flush clear first)');
    await g.clearThenClose();
  }

  /// Large image per the user's choice: the poster via external-assets, the
  /// app logo, or nothing. Unconfigured values fall back to the old behavior
  /// (poster, else logo) so an update never blanks existing presence.
  Future<String?> _resolveLarge(String? posterUrl) async {
    final src = largeImageSrc;
    if (src == 'off') return null;
    if (src == 'logo' || posterUrl == null) return _appLogoKey();
    return await _externalAsset(posterUrl) ?? await _appLogoKey();
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
    // The native SDK resolves artwork URLs itself.
    if (supportsNativeDiscordPresence) return url;
    final cached = _assetCache[url];
    if (cached != null) return cached;
    final token = await getValidAccessToken();
    if (token == null || token.isEmpty || !DiscordConfig.configured) {
      return null;
    }
    try {
      final r = await _dio.post<dynamic>(
        '${DiscordConfig.api}/applications/${DiscordConfig.applicationId}/external-assets',
        data: {
          'urls': [url],
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
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
