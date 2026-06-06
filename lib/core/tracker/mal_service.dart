import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:url_launcher/url_launcher.dart';

import '../environment.dart';
import '../models/watch_status.dart';
import 'tracker.dart';

/// MyAnimeList tracker. OAuth2 with PKCE (plain method, no client secret).
/// Access tokens expire (~31 days) so we persist the refresh token and renew
/// on demand. Anime is identified by its MAL id directly (or a title search
/// fallback). Writes go to `PATCH /v2/anime/{id}/my_list_status`.
class MalService extends ChangeNotifier implements Tracker {
  MalService(this._dio) {
    _linkSub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _onLink(uri);
    }).catchError((_) {});
  }

  final Dio _dio;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Completer<bool>? _pending;

  static const String boxName = 'mal';
  static const String _authBase = 'https://myanimelist.net/v1/oauth2';
  static const String _api = 'https://api.myanimelist.net/v2';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  Box get _box => Hive.box(boxName);

  @override
  String get displayName => 'MyAnimeList';

  @override
  bool get isConnected =>
      (_box.get('accessToken') as String?)?.isNotEmpty == true &&
      _box.get('viewerName') != null;

  @override
  String? get viewerName => _box.get('viewerName') as String?;
  @override
  String? get viewerAvatar => _box.get('viewerAvatar') as String?;

  @override
  bool get autoSync => (_box.get('autoSync') as bool?) ?? true;
  @override
  set autoSync(bool value) {
    _box.put('autoSync', value);
    notifyListeners();
  }

  // ── OAuth (PKCE) ────────────────────────────────────────────────────────────

  String _randomString(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  @override
  Future<bool> connect() async {
    final verifier = _randomString(96); // plain: challenge == verifier
    final state = _randomString(16);
    await _box.put('codeVerifier', verifier);
    await _box.put('state', state);
    final url = Uri.parse(
      '$_authBase/authorize?response_type=code'
      '&client_id=${Environment.malClientId}'
      '&code_challenge=$verifier&code_challenge_method=plain'
      '&state=$state'
      '&redirect_uri=${Uri.encodeComponent(Environment.malRedirectUri)}',
    );
    _pending = Completer<bool>();
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok) {
      _pending = null;
      return false;
    }
    try {
      return await _pending!.future.timeout(const Duration(minutes: 3));
    } catch (_) {
      _pending = null;
      return false;
    }
  }

  void _onLink(Uri uri) {
    if (uri.scheme != Environment.trackerRedirectScheme ||
        uri.host != Environment.malRedirectHost) {
      return;
    }
    _handleRedirect(uri);
  }

  Future<void> _handleRedirect(Uri uri) async {
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      _resolvePending(false);
      return;
    }
    final verifier = _box.get('codeVerifier') as String?;
    if (verifier == null) {
      _resolvePending(false);
      return;
    }
    try {
      final res = await _dio.post<dynamic>(
        '$_authBase/token',
        data: {
          'client_id': Environment.malClientId,
          'grant_type': 'authorization_code',
          'code': code,
          'code_verifier': verifier,
          'redirect_uri': Environment.malRedirectUri,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final ok = await _storeToken(res.data);
      if (!ok) {
        _resolvePending(false);
        return;
      }
      await _fetchViewer();
      notifyListeners();
      _resolvePending(viewerName != null);
    } catch (_) {
      _resolvePending(false);
    }
  }

  void _resolvePending(bool ok) {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete(ok);
  }

  Future<bool> _storeToken(dynamic data) async {
    if (data is! Map) return false;
    final access = data['access_token'] as String?;
    if (access == null || access.isEmpty) return false;
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 2592000;
    await _box.put('accessToken', access);
    await _box.put('refreshToken', data['refresh_token'] as String?);
    await _box.put(
      'expiresAt',
      DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    );
    return true;
  }

  /// A valid access token, refreshing if expired. Null if not connectable.
  Future<String?> _validToken() async {
    final token = _box.get('accessToken') as String?;
    if (token == null || token.isEmpty) return null;
    final expiresAt = (_box.get('expiresAt') as int?) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < expiresAt - 60000) return token;
    // Expired — refresh.
    final refresh = _box.get('refreshToken') as String?;
    if (refresh == null) return token; // try anyway
    try {
      final res = await _dio.post<dynamic>(
        '$_authBase/token',
        data: {
          'client_id': Environment.malClientId,
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (await _storeToken(res.data)) return _box.get('accessToken') as String?;
    } catch (_) {}
    return null;
  }

  Future<void> _fetchViewer() async {
    final token = _box.get('accessToken') as String?;
    if (token == null) return;
    try {
      final res = await _dio.get<dynamic>(
        '$_api/users/@me?fields=name,picture',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is Map && d['name'] != null) {
        await _box.put('viewerName', '${d['name']}');
        final pic = d['picture'];
        if (pic is String) await _box.put('viewerAvatar', pic);
      }
    } catch (_) {}
  }

  @override
  Future<void> disconnect() async {
    for (final k in const [
      'accessToken',
      'refreshToken',
      'expiresAt',
      'viewerName',
      'viewerAvatar',
    ]) {
      await _box.delete(k);
    }
    notifyListeners();
  }

  // ── Anime resolution (MAL id is direct; else title search) ──────────────────

  /// Returns `(id, total episodes)` for the anime, or null.
  Future<({int id, int? total})?> _resolve(int? malId, String? title) async {
    final token = await _validToken();
    if (token == null) return null;
    if (malId != null) {
      return (id: malId, total: await _totalEpisodes(malId, token));
    }
    if (title == null || title.trim().isEmpty) return null;
    final key = title.trim().toLowerCase();
    final cached = (_box.get('title2mal') as Map?)?[key];
    if (cached is int) return (id: cached, total: await _totalEpisodes(cached, token));
    try {
      final res = await _dio.get<dynamic>(
        '$_api/anime?q=${Uri.encodeComponent(title)}&limit=1&fields=num_episodes',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final list = (res.data is Map) ? (res.data['data'] as List?) : null;
      final node = (list != null && list.isNotEmpty)
          ? (list.first as Map)['node'] as Map?
          : null;
      final id = (node?['id'] as num?)?.toInt();
      if (id == null) return null;
      final m = Map<String, dynamic>.from((_box.get('title2mal') as Map?) ?? {});
      m[key] = id;
      await _box.put('title2mal', m);
      final total = (node?['num_episodes'] as num?)?.toInt();
      if (total != null && total > 0) await _cacheEps(id, total);
      return (id: id, total: total);
    } catch (_) {
      return null;
    }
  }

  Future<int?> _totalEpisodes(int id, String token) async {
    final cached = (_box.get('eps') as Map?)?['$id'];
    if (cached is int) return cached;
    try {
      final res = await _dio.get<dynamic>(
        '$_api/anime/$id?fields=num_episodes',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final n = (res.data is Map)
          ? (res.data['num_episodes'] as num?)?.toInt()
          : null;
      if (n != null && n > 0) await _cacheEps(id, n);
      return (n != null && n > 0) ? n : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheEps(int id, int total) async {
    final m = Map<String, dynamic>.from((_box.get('eps') as Map?) ?? {});
    m['$id'] = total;
    await _box.put('eps', m);
  }

  int _scrobbled(int id) {
    final v = (_box.get('scrobbled') as Map?)?['$id'];
    return v is int ? v : 0;
  }

  Future<void> _setScrobbled(int id, int progress) async {
    final m = Map<String, dynamic>.from((_box.get('scrobbled') as Map?) ?? {});
    m['$id'] = progress;
    await _box.put('scrobbled', m);
  }

  Future<bool> _patch(int id, Map<String, dynamic> fields) async {
    final token = await _validToken();
    if (token == null) return false;
    try {
      final res = await _dio.patch<dynamic>(
        '$_api/anime/$id/my_list_status',
        data: fields,
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      return res.statusCode != null && res.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  // ── Tracker writes ──────────────────────────────────────────────────────────

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) async {
    if (!isConnected || !autoSync) return;
    final a = await _resolve(malId, title);
    if (a == null) return;
    if (a.total != null && a.total! > 0 && _scrobbled(a.id) >= a.total!) return;
    await _patch(a.id, {'status': 'watching'});
  }

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    required int episode,
  }) async {
    if (!isConnected || !autoSync || episode <= 0) return;
    final a = await _resolve(malId, title);
    if (a == null) return;
    if (episode <= _scrobbled(a.id)) return; // never go backwards / repeat
    var ep = episode;
    if (a.total != null && a.total! > 0 && ep > a.total!) ep = a.total!;
    final status = (a.total != null && a.total! > 0 && ep >= a.total!)
        ? 'completed'
        : 'watching';
    final ok = await _patch(a.id, {
      'status': status,
      'num_watched_episodes': ep,
    });
    if (ok) await _setScrobbled(a.id, ep);
  }

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    required WatchStatus status,
  }) async {
    if (!isConnected) return;
    final a = await _resolve(malId, title);
    if (a == null) return;
    final fields = <String, dynamic>{'status': status.mal};
    if (status == WatchStatus.completed && a.total != null && a.total! > 0) {
      fields['num_watched_episodes'] = a.total;
      await _setScrobbled(a.id, a.total!);
    }
    await _patch(a.id, fields);
  }

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) async {
    if (!isConnected) return;
    final a = await _resolve(malId, title);
    if (a == null) return;
    final token = await _validToken();
    if (token == null) return;
    try {
      await _dio.delete<dynamic>(
        '$_api/anime/${a.id}/my_list_status',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      await _setScrobbled(a.id, 0);
    } catch (_) {}
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }
}
