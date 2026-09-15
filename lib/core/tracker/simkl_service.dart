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
import '../zmode/simkl_catalogue.dart';
import '../platform/apple_tv.dart';
import 'tracker.dart';

/// Simkl tracker (movies + TV + anime). OAuth2 authorization-code with a client
/// secret; tokens don't expire. Every API call carries `Authorization: Bearer`
/// plus the `simkl-api-key` header. Anime is identified by its MAL id; status
/// goes to `/sync/add-to-list`, watched episodes to `/sync/history`.
class SimklService extends ChangeNotifier implements Tracker {
  SimklService(this._dio) {
    // app_links has no tvOS impl; TV connects trackers via phone QR pairing.
    if (isAppleTv) return;
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
      final ok = res.statusCode != null && res.statusCode! < 300;
      // A rejected sync used to be completely silent — the bool came back
      // false and every caller dropped it, so "Simkl isn't tracking me" had
      // nothing behind it in a shared log. Only the failures are logged;
      // a working scrobble stays quiet.
      if (!ok) {
        debugPrint('[simkl] POST $path → ${res.statusCode} ${res.data}');
      }
      return ok;
    } catch (e) {
      debugPrint('[simkl] POST $path failed: $e');
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
    // The library just changed, so the cached copy is a lie. Dropped
    // FIRST, so a throw further down still leaves it correct.
    invalidateListCache();
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
    int? season,
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false, // no manga/novel API to disambiguate — ignored
  }) async {
    // The library just changed, so the cached copy is a lie. Dropped
    // FIRST, so a throw further down still leaves it correct.
    invalidateListCache();
    if (kind == MediaKind.manga) return; // Simkl has no manga/novel API
    if (!isConnected || !autoSync || episode <= 0) return;
    final t = _target(malId, tmdbId, tmdbIsTv, imdbId);
    if (t == null) return;
    final bool isMovie = t.bucket == 'movies';
    final obj = isMovie
        ? {'ids': t.ids} // a movie: mark the whole thing watched
        : {'ids': t.ids, ...watchedBody(episode, season, seasonEpisode, malId)};
    final ok = await _post('/sync/history', _body(t, obj));
    // Logged either way, not just on failure. A scrobble happens once per
    // finished episode, so it's a line an hour at worst — and "Simkl says I'm
    // still on S3E2" is otherwise unanswerable: nothing recorded what we sent
    // or whether Simkl took it.
    debugPrint(
      '[simkl] scrobble ${t.ids} '
      // What actually goes in the request, not what the source called it.
      // Printing the source's number here once read as "s3e19" for an episode
      // correctly sent as s3e3 — a log that disagrees with the request is
      // worse than none.
      '${obj.containsKey('seasons') ? 's${season}e1-$seasonEpisode' : 'e1-$episode'} '
      '${obj.containsKey('seasons') ? '(seasoned' : '(flat'}'
      // Only when the source called it something else, which is the case
      // worth being able to spot in a shared log.
      '${obj.containsKey('seasons') && seasonEpisode != episode ? ', source e$episode)' : ')'} '
      '→ ${ok ? 'ok' : 'rejected'}',
    );
  }

  /// The watched-episode half of a `/sync/history` show entry.
  ///
  /// Simkl keeps a series as ONE entry with seasons inside it, so an episode
  /// number alone can't say which season — S3E3 and S1E3 are both "3". That is
  /// why a multi-season series looked stuck: every episode landed against the
  /// same season no matter what was actually watched.
  ///
  /// The season is only sent when it can be trusted:
  ///
  /// - [season] must be non-null, i.e. the source genuinely reported one.
  ///   Callers pass `Episode.season`, never `seasonOf()` — the latter falls
  ///   back to parsing the episode TITLE, and a guess written into someone's
  ///   history is worse than the flat numbering it replaces.
  /// - [seasonEpisode] must be known — the episode's position INSIDE its
  ///   season. [episode] is whatever the source calls it, and sources disagree:
  ///   one numbers Reacher's season 3 as 17-24, another as 1-8. Sending 19 as
  ///   "season 3 episode 19" records an episode that season doesn't have, and
  ///   Simkl accepts it with a 2xx while storing nothing — which reads as
  ///   working right up until you look at the website.
  /// - [malId] must be null. A MAL id resolves to a season-specific anime
  ///   entry whose episodes start at 1, so "season 3" is meaningless there and
  ///   sending it would break the anime path, which is correct today.
  ///
  /// Anything else keeps the flat shape this has always sent.
  @visibleForTesting
  static Map<String, dynamic> watchedBody(
    int episode,
    int? season,
    int? seasonEpisode,
    int? malId,
  ) {
    if (season == null || season <= 0 || seasonEpisode == null ||
        seasonEpisode <= 0 || malId != null) {
      return {'episodes': _upTo(episode)};
    }
    return {
      'seasons': [
        {'number': season, 'episodes': _upTo(seasonEpisode)},
      ],
    };
  }

  /// Episodes 1..[n], which is how progress is expressed to Simkl.
  ///
  /// MAL and AniList keep a high-water mark: say "episode 8" and the list reads
  /// 8/220. Simkl instead counts the DISTINCT episodes it has been told about,
  /// so sending only the one just finished left an account that had watched
  /// eight episodes reading "Watching · 1". [setStatus] already worked around
  /// this; scrobbling never did, which is the other half of "Simkl tracking
  /// doesn't work".
  ///
  /// Re-sending the earlier ones every time is deliberate: it costs one request
  /// either way, Simkl ignores episodes it already has, and it self-heals a
  /// history with gaps — episodes watched before the account was connected, or
  /// on another device, or skipped.
  static List<Map<String, dynamic>> _upTo(int n) => [
    for (var i = 1; i <= n; i++) {'number': i},
  ];

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
    // The library just changed, so the cached copy is a lie. Dropped
    // FIRST, so a throw further down still leaves it correct.
    invalidateListCache();
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
    // The library just changed, so the cached copy is a lie. Dropped
    // FIRST, so a throw further down still leaves it correct.
    invalidateListCache();
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

  /// The last parsed library, and when it landed.
  ///
  /// `/sync/all-items?extended=full` returns the WHOLE library — 1024 items
  /// for the account in the report this came from — and a shared log caught it
  /// running 37 times in two hours, three of those inside three seconds. Simkl
  /// enforces a daily request budget, which is how tracking quietly stops
  /// working halfway through a session.
  ///
  /// HomeCubit caches it too, but drops that on every `load(reset: true)` — a
  /// source switch, a retry, pull-to-refresh — none of which change what is on
  /// somebody's Simkl list. This survives those.
  ///
  /// Short on purpose, and every write below clears it outright, so adding,
  /// removing or rescoring an entry shows immediately rather than after a
  /// timer.
  List<TrackerListItem>? _listCache;
  DateTime? _listCacheAt;
  static const Duration listCacheTtl = Duration(minutes: 5);

  /// Whether a library cached at [at] may still be served at [now]. Pulled
  /// out so the window is testable without a Dio, a Hive box and a login.
  @visibleForTesting
  static bool listCacheFresh(DateTime? at, DateTime now) =>
      at != null && now.difference(at) < listCacheTtl;

  /// Forget the cached library. Called by every write in this class, and
  /// available to a caller that genuinely wants fresh data.
  void invalidateListCache() {
    _listCache = null;
    _listCacheAt = null;
  }


  /// Read the connected user's full Simkl library — anime, TV shows AND movies —
  /// as metadata stubs + status. Best-effort: `[]` when disconnected or on ANY
  /// error (never throws).
  @override
  Future<List<TrackerListItem>> fetchList() async {
    if (!isConnected) return const [];
    final hit = _listCache;
    final at = _listCacheAt;
    if (hit != null && listCacheFresh(at, DateTime.now())) return hit;
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
          // The user's own list is the best id map we get: these are the
          // titles they actually open, and every entry carries both ids. Free
          // here, saves a lookup later.
          if (tmdbId != null && simklId != null) {
            SimklCatalogue.rememberSimklId(tmdbId, simklId);
          }
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
            // `extended=full` carries the total on both the entry and the
            // nested media; take whichever is present. No next-airing field
            // exists on this endpoint, so that stays null.
            totalEpisodes: _asInt(
                e['total_episodes_count'] ?? media['total_episodes_count']),
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
      _listCache = out;
      _listCacheAt = DateTime.now();
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
    // Simkl has no cheap single-item status read, so the library is filtered
    // instead — by MAL id (anime), a pinned Simkl id, or TMDB id (films and
    // series, which carry no MAL id).
    //
    // Movies and TV used to bail out here, which meant Apply really did write
    // to Simkl and the Tracking button then had nothing to re-read, so its
    // icon never changed and the sync looked like it had failed. The library
    // already carries `tmdbId` for both buckets (see parseBucket), so there is
    // nothing extra to fetch.
    final pinned = int.tryParse(pinnedId ?? '');
    if (malId == null && pinned == null && tmdbId == null) return null;
    final list = await fetchList();
    for (final it in list) {
      final matchesMal = malId != null && it.item.malId == malId;
      final matchesPinned =
          pinned != null && it.item.id == 'tracker:simkl:$pinned';
      // TMDB numbers a film and a series independently, so the same id is two
      // different titles depending on which. Matching the number alone would
      // hand back somebody else's entry — the kind has to agree too.
      final matchesTmdb = tmdbId != null &&
          it.item.tmdbId == tmdbId &&
          it.tmdbIsTv == tmdbIsTv;
      if (matchesMal || matchesPinned || matchesTmdb) {
        // Library ids are stored as `tracker:simkl:<id>`; the trailing id is
        // what simkl.com puts in a url. Anything else shape-wise → no link.
        const prefix = 'tracker:simkl:';
        final simklId = it.item.id.startsWith(prefix)
            ? it.item.id.substring(prefix.length)
            : null;
        return TrackerEntry(
          trackerName: displayName,
          onList: true,
          // simkl.com files these under three different paths; /anime/ for a
          // film would 404. Anime stays exactly as it was.
          url: simklId == null
              ? null
              : 'https://simkl.com/'
                    '${matchesMal || malId != null ? 'anime' : (it.tmdbIsTv ? 'tv' : 'movies')}'
                    '/$simklId',
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
    // The library just changed, so the cached copy is a lie. Dropped
    // FIRST, so a throw further down still leaves it correct.
    invalidateListCache();
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
