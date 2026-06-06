import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:url_launcher/url_launcher.dart';

import '../environment.dart';
import '../models/watch_status.dart';
import 'tracker.dart';

/// Simkl tracker (movies + TV + anime). OAuth2 authorization-code with a client
/// secret; tokens don't expire. Every API call carries `Authorization: Bearer`
/// plus the `simkl-api-key` header. Anime is identified by its MAL id; status
/// goes to `/sync/add-to-list`, watched episodes to `/sync/history`.
class SimklService extends ChangeNotifier implements Tracker {
  SimklService(this._dio) {
    _linkSub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _onLink(uri);
    }).catchError((_) {});
  }

  final Dio _dio;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Completer<bool>? _pending;

  static const String boxName = 'simkl';
  static const String _api = 'https://api.simkl.com';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  Box get _box => Hive.box(boxName);

  @override
  String get displayName => 'Simkl';

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

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${_box.get('accessToken')}',
    'simkl-api-key': Environment.simklClientId,
    'Content-Type': 'application/json',
  };

  // ── OAuth (authorization code + secret) ─────────────────────────────────────

  @override
  Future<bool> connect() async {
    final url = Uri.parse(
      'https://simkl.com/oauth/authorize?response_type=code'
      '&client_id=${Environment.simklClientId}'
      '&redirect_uri=${Uri.encodeComponent(Environment.simklRedirectUri)}',
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
        uri.host != Environment.simklRedirectHost) {
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
    try {
      final res = await _dio.post<dynamic>(
        '$_api/oauth/token',
        data: {
          'code': code,
          'client_id': Environment.simklClientId,
          'client_secret': Environment.simklClientSecret,
          'redirect_uri': Environment.simklRedirectUri,
          'grant_type': 'authorization_code',
        },
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final token = (res.data is Map) ? res.data['access_token'] as String? : null;
      if (token == null || token.isEmpty) {
        _resolvePending(false);
        return;
      }
      await _box.put('accessToken', token);
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

  Future<void> _fetchViewer() async {
    try {
      final res = await _dio.post<dynamic>(
        '$_api/users/settings',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final user = (res.data is Map) ? res.data['user'] as Map? : null;
      if (user != null && user['name'] != null) {
        await _box.put('viewerName', '${user['name']}');
        final av = user['avatar'];
        if (av is String) await _box.put('viewerAvatar', av);
      }
    } catch (_) {}
  }

  @override
  Future<void> disconnect() async {
    for (final k in const ['accessToken', 'viewerName', 'viewerAvatar']) {
      await _box.delete(k);
    }
    notifyListeners();
  }

  // ── Writes (anime via MAL id, movies/series via TMDB id) ────────────────────

  /// Resolve which Simkl bucket + external id to use. Anime → `shows` with
  /// `ids.mal`; series → `shows` with `ids.tmdb`; movie → `movies` with
  /// `ids.tmdb`. Null when there's no usable id (Simkl needs one).
  ({String bucket, Map<String, dynamic> ids})? _target(
    int? malId,
    int? tmdbId,
    bool tmdbIsTv,
  ) {
    if (malId != null) return (bucket: 'shows', ids: {'mal': '$malId'});
    if (tmdbId != null) {
      return (
        bucket: tmdbIsTv ? 'shows' : 'movies',
        ids: {'tmdb': '$tmdbId'},
      );
    }
    return null;
  }

  Future<bool> _post(String path, Map<String, dynamic> body) async {
    try {
      final res = await _dio.post<dynamic>(
        '$_api$path',
        data: body,
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      return res.statusCode != null && res.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  /// `{shows:[obj], movies:[]}` or `{movies:[obj], shows:[]}` for a target.
  Map<String, dynamic> _body(
    ({String bucket, Map<String, dynamic> ids}) t,
    Map<String, dynamic> obj,
  ) => {
    'movies': t.bucket == 'movies' ? [obj] : [],
    'shows': t.bucket == 'shows' ? [obj] : [],
  };

  Future<void> _addToList(
    ({String bucket, Map<String, dynamic> ids})? t,
    String simklStatus,
  ) async {
    if (t == null) return;
    await _post('/sync/add-to-list', _body(t, {'ids': t.ids, 'to': simklStatus}));
  }

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) async {
    if (!isConnected || !autoSync) return;
    // Movies are watched-once; "watching" is meaningless — wait for completion.
    if (malId == null && tmdbId != null && !tmdbIsTv) return;
    await _addToList(_target(malId, tmdbId, tmdbIsTv), 'watching');
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
    final t = _target(malId, tmdbId, tmdbIsTv);
    if (t == null) return;
    final bool isMovie = t.bucket == 'movies';
    final obj = isMovie
        ? {'ids': t.ids} // a movie: mark the whole thing watched
        : {
            'ids': t.ids,
            'episodes': [
              {'number': episode},
            ],
          };
    await _post('/sync/history', _body(t, obj)); // silent on success
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
    await _addToList(_target(malId, tmdbId, tmdbIsTv), status.simkl);
  }

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) async {
    if (!isConnected) return;
    final t = _target(malId, tmdbId, tmdbIsTv);
    if (t == null) return;
    await _post('/sync/history/remove', _body(t, {'ids': t.ids}));
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }
}
