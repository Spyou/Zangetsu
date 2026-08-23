import 'dart:async';
import 'package:watch_app/core/hive/safe_box.dart';
import 'dart:math';

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

/// MAL's list-endpoint root for [kind] — `anime` or `manga` (novels are
/// filed under manga on MAL; there's no separate novel list).
String malRoot(MediaKind kind) => kind == MediaKind.manga ? 'manga' : 'anime';

/// MAL's total-count field for [kind].
String malTotalField(MediaKind kind) =>
    kind == MediaKind.manga ? 'num_chapters' : 'num_episodes';

/// MAL's `my_list_status` progress WRITE field for [kind] (the PATCH body
/// key). For manga this is also the read name; for anime it is NOT — MAL's
/// anime API is asymmetric (see [malProgressReadField]).
String malProgressField(MediaKind kind) =>
    kind == MediaKind.manga ? 'num_chapters_read' : 'num_watched_episodes';

/// MAL's `my_list_status` progress READ field for [kind] (the field name in
/// a GET response). Manga shares the write name (`num_chapters_read`); anime
/// does NOT — the response uses `num_episodes_watched`, not
/// `num_watched_episodes`. Collapsing these into one builder is exactly the
/// bug that regressed anime progress reads.
String malProgressReadField(MediaKind kind) =>
    kind == MediaKind.manga ? 'num_chapters_read' : 'num_episodes_watched';

/// Path (relative to `_api`) for the title-search a resolver hits
/// (`_resolve`/`_resolveManga`). Pure + exposed so a test can pin the anime
/// text byte-for-byte — same golden-string technique Task 15 used for
/// AniList's queries.
String malSearchPath(MediaKind kind, String title) =>
    '${malRoot(kind)}?q=${Uri.encodeComponent(title)}&limit=1&fields=${malTotalField(kind)}';

/// Path for the by-id total-count lookup (`_totalEpisodes`/`_totalChapters`).
String malTotalPath(MediaKind kind, int id) =>
    '${malRoot(kind)}/$id?fields=${malTotalField(kind)}';

/// Path for the single-entry read ([MalService.fetchEntry]).
String malEntryPath(MediaKind kind, int id) =>
    '${malRoot(kind)}/$id?fields=${malTotalField(kind)},my_list_status';

/// Path for the match-fixer search ([MalService.searchEntries]).
String malSearchEntriesPath(MediaKind kind, String query) =>
    '${malRoot(kind)}?q=${Uri.encodeComponent(query)}&limit=12'
    '&fields=${malTotalField(kind)},media_type,start_season,main_picture';

/// Path for a write/delete against `my_list_status` (`_patch`/`removeFromList`).
String malListStatusPath(MediaKind kind, int id) =>
    '${malRoot(kind)}/$id/my_list_status';

/// Path for the whole-library read-back ([MalService.fetchList]) — MAL's
/// `animelist`/`mangalist` user endpoints. Same envelope for both
/// (`data[].node` + `data[].list_status` + `paging.next`); what differs is
/// the total-count field ([malTotalField]) and, for manga only, `media_type`
/// — the field that tells a light novel apart from a manga. Anime doesn't
/// select `media_type`, so its request stays byte-identical.
String malUserListPath(MediaKind kind) =>
    'users/@me/${malRoot(kind)}list'
    '?fields=list_status,${malTotalField(kind)},main_picture'
    '${kind == MediaKind.manga ? ',media_type' : ''}&limit=1000&nsfw=true';

/// Map a MAL `list_status.status` to our [WatchStatus] (null → skip). Handles
/// both the anime strings (`watching`/`plan_to_watch`) and the manga ones
/// (`reading`/`plan_to_read`) — the shared values (`completed`/`on_hold`/
/// `dropped`) are spelled the same on both lists.
WatchStatus? malWatchStatus(String? status) => switch (status) {
  'watching' || 'reading' => WatchStatus.watching,
  'plan_to_watch' || 'plan_to_read' => WatchStatus.planning,
  'completed' => WatchStatus.completed,
  'on_hold' => WatchStatus.paused,
  'dropped' => WatchStatus.dropped,
  _ => null,
};

/// Which [ProviderType] a MAL manga-list node with this `media_type` belongs
/// to. MAL has no novel list — light novels sit on the manga list and are only
/// distinguishable by `media_type`, so without this split novel mode is empty.
/// Anything else (`manga`, `manhwa`, `one_shot`, an unknown value, or a null
/// when the field wasn't selected) is treated as manga: a wrong-but-visible
/// bucket beats a silently dropped entry.
ProviderType malProviderType(MediaKind kind, String? mediaType) {
  if (kind != MediaKind.manga) return ProviderType.anime;
  return (mediaType == 'novel' || mediaType == 'light_novel')
      ? ProviderType.novel
      : ProviderType.manga;
}

/// Parse ONE page of a MAL user-list response into library stubs. Pure +
/// top-level so a test can feed it a recorded response without a live API.
///
/// Progress is read with [malProgressReadField], NOT [malProgressField] — for
/// anime MAL answers with `num_episodes_watched` while accepting
/// `num_watched_episodes` on a write, and reading with the write name silently
/// nulls every user's progress.
List<TrackerListItem> parseMalListPage(Object? body, MediaKind kind) {
  if (body is! Map) return const [];
  final data = body['data'];
  if (data is! List) return const [];
  final progressField = malProgressReadField(kind);
  final out = <TrackerListItem>[];
  for (final e in data) {
    if (e is! Map) continue;
    final node = e['node'] as Map?;
    final ls = e['list_status'] as Map?;
    if (node == null || ls == null) continue;
    final id = (node['id'] as num?)?.toInt();
    if (id == null) continue;
    final status = malWatchStatus(ls['status'] as String?);
    if (status == null) continue;
    final pic = node['main_picture'] as Map?;
    final cover = (pic?['large'] as String?) ?? (pic?['medium'] as String?);
    final score = (ls['score'] as num?)?.toDouble();
    // MAL returns updated_at inside list_status by default, so this needs no
    // change to the request — it was simply being dropped.
    final updated = DateTime.tryParse('${ls['updated_at'] ?? ''}');
    out.add(
      TrackerListItem(
        updatedAt: updated,
        item: MediaItem(
          // Reading kinds get their own id namespace — MAL's anime and manga
          // id spaces overlap, so `tracker:mal:21` would otherwise name two
          // different titles.
          id: kind == MediaKind.manga
              ? 'tracker:mal:manga:$id'
              : 'tracker:mal:$id',
          title: '${node['title'] ?? ''}',
          cover: cover,
          type: malProviderType(kind, node['media_type'] as String?),
          malId: id,
          url: '',
          sourceId: '',
        ),
        status: status,
        // Chapters read for manga/novel, episodes watched for anime.
        progress: (ls[progressField] as num?)?.toInt(),
        score: (score != null && score > 0) ? score : null,
      ),
    );
  }
  return out;
}

/// MyAnimeList tracker. OAuth2 with PKCE (plain method, no client secret).
/// Access tokens expire (~31 days) so we persist the refresh token and renew
/// on demand. Anime is identified by its MAL id directly (or a title search
/// fallback). Writes go to `PATCH /v2/anime/{id}/my_list_status`.
class MalService extends ChangeNotifier implements Tracker {
  MalService(this._dio) {
    _linkSub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    _appLinks
        .getInitialLink()
        .then((uri) {
          if (uri != null) _onLink(uri);
        })
        .catchError((_) {});
  }

  final Dio _dio;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Completer<bool>? _pending;

  static const String boxName = 'mal';
  static const String _authBase = 'https://myanimelist.net/v1/oauth2';
  static const String _api = 'https://api.myanimelist.net/v2';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  @override
  String get displayName => 'MyAnimeList';

  @override
  bool get supportsReading => true; // MAL has a manga list (incl. light novels)

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
      if (await _storeToken(res.data)) {
        return _box.get('accessToken') as String?;
      }
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
    if (cached is int) {
      return (id: cached, total: await _totalEpisodes(cached, token));
    }
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
      final m = Map<String, dynamic>.from(
        (_box.get('title2mal') as Map?) ?? {},
      );
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

  // ── Manga/novel resolution — a SEPARATE id-resolver cache. MAL's anime and
  // manga id spaces overlap (a manga malId can equal an unrelated anime's
  // malId), so this must not share `_resolve`'s `title2mal`/`eps` maps — a
  // shared cache could return a stale cross-kind id/total for the same
  // numeric malId. Same shape as `_resolve`/`_totalEpisodes`, hitting the
  // `/v2/manga` root instead. ─────────────────────────────────────────────

  /// Returns `(id, total chapters)` for the manga/novel, or null.
  Future<({int id, int? total})?> _resolveManga(
    int? malId,
    String? title,
  ) async {
    final token = await _validToken();
    if (token == null) return null;
    if (malId != null) {
      return (id: malId, total: await _totalChapters(malId, token));
    }
    if (title == null || title.trim().isEmpty) return null;
    final key = title.trim().toLowerCase();
    final cached = (_box.get('title2mal_manga') as Map?)?[key];
    if (cached is int) {
      return (id: cached, total: await _totalChapters(cached, token));
    }
    try {
      final res = await _dio.get<dynamic>(
        '$_api/${malSearchPath(MediaKind.manga, title)}',
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
      final m = Map<String, dynamic>.from(
        (_box.get('title2mal_manga') as Map?) ?? {},
      );
      m[key] = id;
      await _box.put('title2mal_manga', m);
      final total = (node?['num_chapters'] as num?)?.toInt();
      if (total != null && total > 0) await _cacheChapters(id, total);
      return (id: id, total: total);
    } catch (_) {
      return null;
    }
  }

  Future<int?> _totalChapters(int id, String token) async {
    final cached = (_box.get('eps_manga') as Map?)?['$id'];
    if (cached is int) return cached;
    try {
      final res = await _dio.get<dynamic>(
        '$_api/${malTotalPath(MediaKind.manga, id)}',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final n = (res.data is Map)
          ? (res.data['num_chapters'] as num?)?.toInt()
          : null;
      if (n != null && n > 0) await _cacheChapters(id, n);
      return (n != null && n > 0) ? n : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheChapters(int id, int total) async {
    final m = Map<String, dynamic>.from((_box.get('eps_manga') as Map?) ?? {});
    m['$id'] = total;
    await _box.put('eps_manga', m);
  }

  /// [malId]/[title] resolution for [kind] — routes to the anime or manga
  /// resolver (and its own cache). Anime is [_resolve], unchanged.
  Future<({int id, int? total})?> _resolveFor(
    MediaKind kind,
    int? malId,
    String? title,
  ) => kind == MediaKind.manga
      ? _resolveManga(malId, title)
      : _resolve(malId, title);

  // ── Scrobble high-water mark + writes — kind-namespaced for the same
  // overlapping-id-space reason as the resolver cache above. ───────────────

  int _scrobbled(int id, MediaKind kind) {
    final box = kind == MediaKind.manga ? 'scrobbled_manga' : 'scrobbled';
    final v = (_box.get(box) as Map?)?['$id'];
    return v is int ? v : 0;
  }

  Future<void> _setScrobbled(int id, MediaKind kind, int progress) async {
    final box = kind == MediaKind.manga ? 'scrobbled_manga' : 'scrobbled';
    final m = Map<String, dynamic>.from((_box.get(box) as Map?) ?? {});
    m['$id'] = progress;
    await _box.put(box, m);
  }

  Future<bool> _patch(
    int id,
    MediaKind kind,
    Map<String, dynamic> fields,
  ) async {
    final token = await _validToken();
    if (token == null) return false;
    try {
      final res = await _dio.patch<dynamic>(
        '$_api/${malListStatusPath(kind, id)}',
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
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!isConnected || !autoSync) return;
    final a = await _resolveFor(kind, malId, title);
    if (a == null) return;
    if (a.total != null && a.total! > 0 && _scrobbled(a.id, kind) >= a.total!) {
      return;
    }
    await _patch(a.id, kind, {
      'status': malStatusFor(
        WatchStatus.watching,
        reading: kind == MediaKind.manga,
      ),
    });
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
    bool novel = false, // MAL has no format filter for this yet — ignored
  }) async {
    if (!isConnected || !autoSync || episode <= 0) return;
    final a = await _resolveFor(kind, malId, title);
    if (a == null) return;
    if (episode <= _scrobbled(a.id, kind)) {
      return; // never go backwards / repeat
    }
    var ep = episode;
    if (a.total != null && a.total! > 0 && ep > a.total!) ep = a.total!;
    final status = (a.total != null && a.total! > 0 && ep >= a.total!)
        ? 'completed'
        : malStatusFor(WatchStatus.watching, reading: kind == MediaKind.manga);
    final ok = await _patch(a.id, kind, {
      'status': status,
      malProgressField(kind): ep,
    });
    if (ok) await _setScrobbled(a.id, kind, ep);
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
    if (!isConnected) return;
    final a = await _resolveFor(kind, malId, title);
    if (a == null) return;
    final fields = <String, dynamic>{
      'status': malStatusFor(status, reading: kind == MediaKind.manga),
    };
    if (status == WatchStatus.completed && a.total != null && a.total! > 0) {
      fields[malProgressField(kind)] = a.total;
      await _setScrobbled(a.id, kind, a.total!);
    }
    await _patch(a.id, kind, fields);
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
    if (!isConnected) return;
    // A pinned id wins over title/malId resolution — same precedence as
    // fetchEntry, so a corrected match is deleted instead of the guess.
    final id = int.tryParse(pinnedId ?? '') ??
        (await _resolveFor(kind, malId, title))?.id;
    if (id == null) return;
    final token = await _validToken();
    if (token == null) return;
    try {
      await _dio.delete<dynamic>(
        '$_api/${malListStatusPath(kind, id)}',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      await _setScrobbled(id, kind, 0);
    } catch (_) {}
  }

  // ── Tracker reads ───────────────────────────────────────────────────────────

  /// Read the connected user's full MAL library — the anime list AND the manga
  /// list (which is where MAL keeps light novels too; [parseMalListPage]
  /// splits them back out). Best-effort: `[]` on any error, never throws.
  @override
  Future<List<TrackerListItem>> fetchList() async {
    if (!isConnected) return const [];
    final token = await _validToken();
    if (token == null) return const [];
    // Each list is fetched + caught independently, so a failing manga read
    // can't take the anime list down with it.
    final both = await Future.wait([
      _fetchListOf(MediaKind.anime, token),
      _fetchListOf(MediaKind.manga, token),
    ]);
    return [...both[0], ...both[1]];
  }

  Future<List<TrackerListItem>> _fetchListOf(
    MediaKind kind,
    String token,
  ) async {
    try {
      final items = <TrackerListItem>[];
      var url = '$_api/${malUserListPath(kind)}';
      for (var page = 0; page < 5; page++) {
        final res = await _dio.get<dynamic>(
          url,
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
            validateStatus: (s) => s != null && s < 500,
          ),
        );
        final body = res.data;
        items.addAll(parseMalListPage(body, kind));
        final paging = (body is Map) ? body['paging'] : null;
        final next = (paging is Map) ? paging['next'] : null;
        if (next is! String || next.isEmpty) break;
        url = next;
      }
      return items;
    } catch (_) {
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
    bool novel = false, // MAL has no format filter for this yet — ignored
  }) async {
    if (!isConnected) return null;
    final token = await _validToken();
    if (token == null) return null;
    final pinned = int.tryParse(pinnedId ?? '');
    final id = pinned ?? (await _resolveFor(kind, malId, title))?.id;
    if (id == null) return null;
    try {
      final res = await _dio.get<dynamic>(
        '$_api/${malEntryPath(kind, id)}',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is! Map) return null;
      final ls = d['my_list_status'] as Map?;
      final total = (d[malTotalField(kind)] as num?)?.toInt();
      final score = (ls?['score'] as num?)?.toDouble();
      final reading = kind == MediaKind.manga;
      final totalOrNull = (total != null && total > 0) ? total : null;
      return TrackerEntry(
        trackerName: displayName,
        onList: ls != null,
        url: 'https://myanimelist.net/${reading ? 'manga' : 'anime'}/$id',
        // MAL returns id/title/main_picture whether or not `fields` asks for
        // them, so this needs no change to the request path.
        title: (d['title'] as String?)?.trim(),
        status: malWatchStatus(ls?['status'] as String?),
        score: (score == null || score == 0) ? null : score,
        progress: (ls?[malProgressReadField(kind)] as num?)?.toInt(),
        maxEpisodes: reading ? null : totalOrNull,
        chapters: reading ? totalOrNull : null,
      );
    } catch (_) {
      return null;
    }
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
    if (!isConnected) return;
    final pinned = int.tryParse(pinnedId ?? '');
    final id = pinned ?? (await _resolveFor(kind, malId, title))?.id;
    if (id == null) return;
    final fields = <String, dynamic>{};
    if (status != null) {
      fields['status'] = malStatusFor(status, reading: kind == MediaKind.manga);
    }
    if (progress != null) fields[malProgressField(kind)] = progress;
    if (score != null) fields['score'] = score.round().clamp(0, 10);
    if (fields.isEmpty) return;
    final ok = await _patch(id, kind, fields);
    if (ok && progress != null) await _setScrobbled(id, kind, progress);
  }

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async {
    if (query.trim().isEmpty) return const [];
    final token = await _validToken();
    if (token == null) return const [];
    try {
      final res = await _dio.get<dynamic>(
        '$_api/${malSearchEntriesPath(kind, query)}',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final list = (res.data is Map) ? (res.data['data'] as List?) : null;
      if (list == null) return const [];
      final out = <TrackerSearchResult>[];
      for (final e in list) {
        final node = (e is Map) ? e['node'] as Map? : null;
        final id = (node?['id'] as num?)?.toInt();
        if (node == null || id == null) continue;
        final pic = node['main_picture'] as Map?;
        final total = (node[malTotalField(kind)] as num?)?.toInt();
        out.add(
          TrackerSearchResult(
            trackerName: displayName,
            id: '$id',
            title: '${node['title'] ?? 'Unknown'}',
            cover: (pic?['medium'] as String?) ?? (pic?['large'] as String?),
            subtitle: _searchSubtitle(node),
            maxEpisodes: (total != null && total > 0) ? total : null,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static String? _searchSubtitle(Map node) {
    final type = (node['media_type'] as String?)?.toUpperCase();
    final year = ((node['start_season'] as Map?)?['year'] as num?)?.toInt();
    final parts = [
      if (type != null && type.isNotEmpty) type,
      if (year != null) '$year',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  // ── Session export/import (TV relay) ────────────────────────────────────

  @override
  Map<String, dynamic>? exportSession() {
    if (!isConnected) return null;
    return {
      'accessToken': _box.get('accessToken'),
      'refreshToken': _box.get('refreshToken'),
      'expiresAt': _box.get('expiresAt'),
      'viewerName': _box.get('viewerName'),
      'viewerAvatar': _box.get('viewerAvatar'),
    };
  }

  @override
  Future<void> importSession(Map<String, dynamic> s) async {
    await _box.put('accessToken', s['accessToken']);
    await _box.put('refreshToken', s['refreshToken']);
    await _box.put('expiresAt', s['expiresAt']);
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
