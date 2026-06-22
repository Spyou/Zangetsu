import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

import 'discord_config.dart';
import 'discord_gateway.dart';
import 'discord_presence.dart';
import 'discord_token_store.dart';

/// Orchestrates Discord Rich Presence: holds the Gateway connection, the opt-in
/// toggle, and builds the "watching" / "browsing" presence. Connects only while
/// enabled + logged in + the app is foreground; clears + disconnects otherwise.
class DiscordRpc {
  DiscordRpc(this._dio);
  final Dio _dio;

  static const String boxName = 'discord';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  Box get _box => Hive.box(boxName);

  DiscordGateway? _gateway;
  String? _token;
  bool _enabled = false;
  bool _foreground = true;
  DiscordActivity? _current;
  final Map<String, String> _assetCache = {}; // posterUrl -> "mp:..." key

  bool get enabled => _enabled;
  bool get loggedIn => _token != null && _token!.isNotEmpty;

  bool get _canRun =>
      _enabled && loggedIn && DiscordConfig.configured && _foreground;

  /// Load persisted state + connect if everything's ready. Call at startup.
  Future<void> start() async {
    _enabled = _box.get('enabled', defaultValue: false) as bool;
    _token = await DiscordTokenStore.read();
    if (_canRun) _connect();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _box.put('enabled', value);
    if (_canRun) {
      _connect();
    } else {
      _disconnect();
    }
  }

  /// Save (or clear, with null) the captured Discord user token.
  Future<void> setToken(String? token) async {
    _token = token;
    if (!loggedIn) {
      await DiscordTokenStore.clear();
      _disconnect();
    } else {
      await DiscordTokenStore.write(token!);
      if (_canRun) _connect();
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  void onForeground() {
    _foreground = true;
    if (_canRun) _connect();
  }

  void onBackground() {
    _foreground = false;
    _disconnect();
  }

  // ── Presence ──────────────────────────────────────────────────────────────
  Future<void> setWatching({
    required String title,
    String? episodeLabel,
    String? posterUrl,
    int? startMs,
    int? endMs,
  }) async {
    if (!_canRun) return;
    final large = posterUrl != null ? await _externalAsset(posterUrl) : null;
    _current = DiscordActivity(
      name: title,
      type: 3, // Watching
      details: episodeLabel,
      state: 'on ${DiscordConfig.appName}',
      largeImage: large ?? DiscordConfig.appLogoAsset,
      largeText: title,
      smallImage: large != null ? DiscordConfig.appLogoAsset : null,
      smallText: 'Watching on ${DiscordConfig.appName}',
      startMs: startMs,
      endMs: endMs,
    );
    _gateway?.setPresence(_current);
  }

  Future<void> setBrowsing({String? title, String? posterUrl}) async {
    if (!_canRun) return;
    final large = posterUrl != null ? await _externalAsset(posterUrl) : null;
    _current = DiscordActivity(
      name: DiscordConfig.appName,
      type: 0, // Playing → "Playing Zangetsu"
      details: title != null ? 'Looking at $title' : 'Browsing',
      largeImage: large ?? DiscordConfig.appLogoAsset,
      largeText: title ?? DiscordConfig.appName,
      smallImage: large != null ? DiscordConfig.appLogoAsset : null,
    );
    _gateway?.setPresence(_current);
  }

  void clear() {
    _current = null;
    _gateway?.setPresence(null);
  }

  // ── Internals ───────────────────────────────────────────────────────────
  void _connect() {
    if (_gateway != null) {
      if (_current != null) _gateway!.setPresence(_current);
      return;
    }
    _gateway = DiscordGateway(_token!)..connect();
    if (_current != null) _gateway!.setPresence(_current);
  }

  void _disconnect() {
    _gateway?.close();
    _gateway = null;
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
    } catch (_) {
      return null; // fall back to the app logo
    }
  }
}
