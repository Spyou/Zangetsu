import 'dart:async';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:url_launcher/url_launcher.dart';

import '../environment.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
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
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  @override
  String get displayName => 'Simkl';

  @override
  bool get supportsReading => false; // Simkl is video-only — no manga/novel API

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

  /// Resolve which Simkl bucket + external ids to use. Anime (mal) and series
  /// go in `shows`, a pure movie in `movies`. Include EVERY id we have (mal +
  /// tmdb + imdb) so Simkl can match on whichever it knows — e.g. a MovieBox
  /// title that we promoted to anime by a season-specific mal Simkl lacks still
  /// resolves via its tmdb id. Null when there's no usable id at all.
  ({String bucket, Map<String, dynamic> ids})? _target(
    int? malId,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
  ) {
    final ids = <String, dynamic>{};
    if (malId != null) ids['mal'] = '$malId';
    if (tmdbId != null) ids['tmdb'] = '$tmdbId';
    if (imdbId != null && imdbId.isNotEmpty) ids['imdb'] = imdbId;
    if (ids.isEmpty) return null;
    final bucket = (malId != null || tmdbIsTv) ? 'shows' : 'movies';
    return (bucket: bucket, ids: ids);
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
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (kind == MediaKind.manga) return; // Simkl has no manga/novel API
    if (!isConnected || !autoSync) return;
    // Movies are watched-once; "watching" is meaningless — wait for completion.
    final hasMovieId = tmdbId != null || (imdbId != null && imdbId.isNotEmpty);
    if (malId == null && !tmdbIsTv && hasMovieId) return;
    await _addToList(_target(malId, tmdbId, tmdbIsTv, imdbId), 'watching');
  }

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    MediaKind kind = MediaKind.anime,
    bool novel = false, // no manga/novel API to disambiguate — ignored
  }) async {
    if (kind == MediaKind.manga) return; // Simkl has no manga/novel API
    if (!isConnected || !autoSync || episode <= 0) return;
    final t = _target(malId, tmdbId, tmdbIsTv, imdbId);
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
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (kind == MediaKind.manga) return; // Simkl has no manga/novel API
    if (!isConnected) return;
    await _addToList(_target(malId, tmdbId, tmdbIsTv, imdbId), status.simkl);
  }

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (kind == MediaKind.manga) return; // Simkl has no manga/novel API
    if (!isConnected) return;
    // A pinned id wins over id resolution, exactly as in updateEntry — without
    // it a corrected match removes whatever the app originally guessed.
    final pinned = int.tryParse(pinnedId ?? '');
    final ({String bucket, Map<String, dynamic> ids})? t = pinned != null
        ? (bucket: 'shows', ids: <String, dynamic>{'simkl': '$pinned'})
        : _target(malId, tmdbId, tmdbIsTv, imdbId);
    if (t == null) return;
    await _post('/sync/history/remove', _body(t, {'ids': t.ids}));
  }

  // ── Library read-back (for the My List tracker switcher) ────────────────────

  /// Expand a Simkl `poster` path (e.g. `12/12abcd0e1f2a3b4c`) into a full CDN
  /// url. Simkl serves posters from `simkl.in/posters/<path>_<size>.jpg`; `_m`
  /// is the medium thumbnail. Already-absolute urls pass through unchanged.
  static String? _posterUrl(Object? poster) {
    if (poster is! String || poster.isEmpty) return null;
    if (poster.startsWith('http')) return poster;
    return 'https://simkl.in/posters/${poster}_m.jpg';
  }

  /// Map a Simkl list name to our [WatchStatus]. `notinteresting` collapses to
  /// dropped; unknown values yield null (the entry is skipped).
  static WatchStatus? _statusFromSimkl(String? status) => switch (status) {
    'watching' => WatchStatus.watching,
    'plantowatch' => WatchStatus.planning,
    'completed' => WatchStatus.completed,
    'hold' => WatchStatus.paused,
    'dropped' || 'notinteresting' => WatchStatus.dropped,
    _ => null,
  };

  /// Simkl returns several numeric fields as STRINGS (e.g. `ids.mal:"16498"`),
  /// so a plain `as num?` cast THROWS and would blank the whole list. Parse
  /// defensively — accept num or numeric string, else null.
  static int? _asInt(Object? v) =>
      v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
  static double? _asDouble(Object? v) =>
      v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

  /// Read the connected user's full Simkl library — anime, TV shows AND movies —
  /// as metadata stubs + status. Best-effort: `[]` when disconnected or on ANY
  /// error (never throws).
  @override
  Future<List<TrackerListItem>> fetchList() async {
    if (!isConnected) return const [];
    try {
      // `/sync/all-items` (no type) returns every list: { anime, shows, movies }.
      final res = await _dio.get<dynamic>(
        '$_api/sync/all-items?extended=full',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      if (data is! Map) {
        debugPrint(
          '[simkl] fetchList: unexpected — status=${res.statusCode} '
          '${data.runtimeType}',
        );
        return const [];
      }

      final out = <TrackerListItem>[];
      // Parse one bucket. Anime is keyed by MAL id (type anime); shows/movies by
      // TMDB id (type movie — TV groups under "Movies & TV"). [isTv] lets the
      // edit sheet write shows back to Simkl's `shows` bucket, not `movies`.
      void parseBucket(
        Object? list, {
        required ProviderType type,
        required bool anime,
        required bool isTv,
      }) {
        if (list is! List) return;
        for (final e in list) {
          if (e is! Map) continue;
          final status = _statusFromSimkl(e['status'] as String?);
          if (status == null) continue;
          // Media nests under "show" (anime/shows) or "movie"; some variants
          // inline the fields on the entry itself.
          final media = (e['show'] is Map)
              ? e['show'] as Map
              : (e['movie'] is Map)
                  ? e['movie'] as Map
                  : e;

          final ids = (media['ids'] is Map) ? media['ids'] as Map : const {};
          // Simkl is inconsistent about this key: the sync endpoints answer
          // with `simkl`, /search/* with `simkl_id`. Accept either everywhere
          // rather than guess per endpoint.
          final simklId = _asInt(ids['simkl'] ?? ids['simkl_id']);
          final malId = anime ? _asInt(ids['mal']) : null;
          final tmdbId = anime ? null : _asInt(ids['tmdb']);
          final title = (media['title'] as String?) ??
              (e['title'] as String?) ??
              'Unknown';

          final rawScore = _asDouble(e['user_rating']);
          final score = (rawScore == null || rawScore <= 0) ? null : rawScore;

          // Simkl dates arrive as strings; last_watched_at is the meaningful
          // "updated", with the watchlist-added date as the fallback for
          // something planned but never watched.
          final updatedRaw = (e['last_watched_at'] ?? e['added_to_watchlist_at'])
              ?.toString();
          out.add(TrackerListItem(
            updatedAt: updatedRaw == null
                ? null
                : DateTime.tryParse(updatedRaw.replaceFirst(' ', 'T')),
            item: MediaItem(
              id: 'tracker:simkl:${simklId ?? malId ?? tmdbId ?? out.length}',
              title: title,
              cover: _posterUrl(media['poster']),
              url: '',
              type: type,
              sourceId: '',
              malId: malId,
              tmdbId: tmdbId,
            ),
            status: status,
            progress: _asInt(e['watched_episodes_count']),
            score: score,
            tmdbIsTv: isTv,
          ));
        }
      }

      parseBucket(data['anime'],
          type: ProviderType.anime, anime: true, isTv: false);
      parseBucket(data['shows'],
          type: ProviderType.movie, anime: false, isTv: true);
      parseBucket(data['movies'],
          type: ProviderType.movie, anime: false, isTv: false);

      debugPrint(
        '[simkl] fetchList: ${out.length} items '
        '(anime=${(data['anime'] as List?)?.length ?? 0} '
        'shows=${(data['shows'] as List?)?.length ?? 0} '
        'movies=${(data['movies'] as List?)?.length ?? 0})',
      );
      return out;
    } catch (e) {
      debugPrint('[simkl] fetchList failed: $e');
      return const [];
    }
  }

  // ── Single-entry read/write + search (sync sheet + match-fixer) ─────────────

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false, // no manga/novel API to disambiguate — ignored
  }) async {
    if (kind == MediaKind.manga) return null; // Simkl has no manga/novel API
    if (!isConnected) return null;
    // Simkl has no cheap single-item status read, so filter the anime library
    // (matches by MAL id, or a pinned Simkl id). Movies/TV return null — Simkl
    // still receives writes on Apply via updateEntry, it just can't prefill.
    final pinned = int.tryParse(pinnedId ?? '');
    if (malId == null && pinned == null) return null;
    final list = await fetchList();
    for (final it in list) {
      final matchesMal = malId != null && it.item.malId == malId;
      final matchesPinned =
          pinned != null && it.item.id == 'tracker:simkl:$pinned';
      if (matchesMal || matchesPinned) {
        // Library ids are stored as `tracker:simkl:<id>`; the trailing id is
        // what simkl.com puts in a url. Anything else shape-wise → no link.
        const prefix = 'tracker:simkl:';
        final simklId = it.item.id.startsWith(prefix)
            ? it.item.id.substring(prefix.length)
            : null;
        return TrackerEntry(
          trackerName: displayName,
          onList: true,
          url: simklId == null ? null : 'https://simkl.com/anime/$simklId',
          title: it.item.title,
          status: it.status,
          score: it.score,
          progress: it.progress,
        );
      }
    }
    return null;
  }

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (kind == MediaKind.manga) return; // Simkl has no manga/novel API
    if (!isConnected) return;
    final pinned = int.tryParse(pinnedId ?? '');
    final ({String bucket, Map<String, dynamic> ids})? target = pinned != null
        ? (bucket: 'shows', ids: <String, dynamic>{'simkl': '$pinned'})
        : _target(malId, tmdbId, tmdbIsTv, imdbId);
    if (target == null) return;
    if (status != null) {
      await _addToList(target, status.simkl);
    }
    if (score != null) {
      await _post(
        '/sync/ratings',
        _body(target, {'ids': target.ids, 'rating': score.round().clamp(1, 10)}),
      );
    }
    if (progress != null && progress > 0) {
      // Simkl counts distinct watched episodes, so mark 1..N to set progress N.
      final eps = [for (var n = 1; n <= progress; n++) <String, dynamic>{'number': n}];
      await _post('/sync/history', _body(target, {'ids': target.ids, 'episodes': eps}));
    }
  }

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async {
    if (kind == MediaKind.manga) return const []; // Simkl has no manga/novel API
    if (query.trim().isEmpty) return const [];
    // Simkl keeps anime, movies and TV in SEPARATE catalogues. Searching
    // /search/anime for a movie is how "Change match" came back empty for
    // TMDB titles — the endpoint has to follow the kind.
    final path = switch (kind) {
      MediaKind.movie => 'movie',
      MediaKind.tv => 'tv',
      _ => 'anime',
    };
    try {
      final res = await _dio.get<dynamic>(
        '$_api/search/$path?q=${Uri.encodeComponent(query)}&extended=full&limit=12',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final list = res.data;
      if (list is! List) return const [];
      final out = <TrackerSearchResult>[];
      for (final e in list) {
        if (e is! Map) continue;
        final ids = (e['ids'] is Map) ? e['ids'] as Map : const {};
        // /search/* returns `simkl_id`, not `simkl` — reading only the latter
        // silently dropped EVERY search result, for anime as well as movies,
        // so "Change match" always said "No matches found".
        final simkl = _asInt(ids['simkl'] ?? ids['simkl_id']);
        if (simkl == null) continue;
        final total = _asInt(e['total_episodes']) ?? _asInt(e['episodes']);
        final year = _asInt(e['year']);
        out.add(TrackerSearchResult(
          trackerName: displayName,
          id: '$simkl',
          title: '${e['title'] ?? 'Unknown'}',
          cover: _posterUrl(e['poster']),
          subtitle: year == null ? null : '$year',
          maxEpisodes: (total != null && total > 0) ? total : null,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // ── Session export/import (TV relay) ────────────────────────────────────

  @override
  Map<String, dynamic>? exportSession() {
    if (!isConnected) return null;
    return {
      'accessToken': _box.get('accessToken'),
      'viewerName': _box.get('viewerName'),
      'viewerAvatar': _box.get('viewerAvatar'),
    };
  }

  @override
  Future<void> importSession(Map<String, dynamic> s) async {
    await _box.put('accessToken', s['accessToken']);
    await _box.put('viewerName', s['viewerName']);
    await _box.put('viewerAvatar', s['viewerAvatar']);
    notifyListeners();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }
}
