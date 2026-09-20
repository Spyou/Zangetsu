import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../environment.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../platform/apple_tv.dart';
import 'tracker.dart';

/// MangaBaka tracker — **manga, manhwa, manhua AND novels**. No anime: the
/// site has /manga, /manhwa, /manhua and /novel sections and nothing else, and
/// the API's `type` field returns exactly those (plus `other`).
///
/// Novels need no separate [MediaKind]: this app files them under
/// `MediaKind.manga` with `novel: true`, the same way AniList does, so they
/// sync through the identical path. The flag matters at resolution — a series
/// that exists as both a light novel and a manga adaptation would otherwise
/// write a novel's progress onto the manga entry.
///
/// OAuth 2.0 authorization-code with **PKCE and no client secret**: an installed
/// app cannot keep one, since anything shipped in the APK can be extracted.
/// That differs from [SimklService], which posts a secret, so don't copy this
/// pattern back onto the others.
///
/// MangaBaka's published API docs describe only metadata and never mention
/// OAuth, tokens, or the `/v1/my/*` endpoints beyond a rate-limit table. The
/// authoritative source is the discovery document at
/// `https://mangabaka.org/.well-known/openid-configuration`, and `library.write`
/// is an official scope there — writing to a user's library is supported, not a
/// workaround.
class MangaBakaService extends ChangeNotifier implements Tracker {
  MangaBakaService(this._dio) {
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

  /// The verifier for the consent currently in flight. Held in memory only —
  /// it is single-use and must not outlive the app, let alone reach disk.
  String? _verifier;

  static const String boxName = 'mangabaka';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  @override
  String get displayName => 'MangaBaka';

  /// The only tracker that is reading-ONLY. MangaBaka has no anime library at
  /// all, so every anime write here is a deliberate no-op rather than a write
  /// onto some wrong entry. Covers manga/manhwa/manhua and novels alike.
  @override
  bool get supportsReading => true;

  @override
  bool get isConnected =>
      (_box.get('accessToken') as String?)?.isNotEmpty == true;

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

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  // ── PKCE ─────────────────────────────────────────────────────────────────

  static final Random _rng = Random.secure();

  /// RFC 7636 code verifier: 43–128 chars of unreserved characters. 32 random
  /// bytes base64url-encoded lands at 43, the minimum, which is plenty.
  static String newVerifier() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// S256 challenge — the only method MangaBaka advertises. Base64url of the
  /// SHA-256 of the verifier's ASCII bytes, unpadded.
  static String challengeFor(String verifier) =>
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');

  // ── connect / disconnect ─────────────────────────────────────────────────

  @override
  Future<bool> connect() async {
    final verifier = newVerifier();
    _verifier = verifier;
    final url = Uri.parse(
      '${Environment.mangabakaAuthorizeUrl}?response_type=code'
      '&client_id=${Environment.mangabakaClientId}'
      '&redirect_uri=${Uri.encodeComponent(Environment.mangabakaRedirectUri)}'
      '&scope=${Uri.encodeComponent(Environment.mangabakaScopes)}'
      '&code_challenge=${challengeFor(verifier)}'
      '&code_challenge_method=S256',
    );
    _pending = Completer<bool>();
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok) {
      _pending = null;
      _verifier = null;
      return false;
    }
    try {
      return await _pending!.future.timeout(const Duration(minutes: 3));
    } catch (_) {
      _pending = null;
      _verifier = null;
      return false;
    }
  }

  void _onLink(Uri uri) {
    if (uri.scheme != Environment.trackerRedirectScheme ||
        uri.host != Environment.mangabakaRedirectHost) {
      return;
    }
    _handleRedirect(uri);
  }

  Future<void> _handleRedirect(Uri uri) async {
    final code = uri.queryParameters['code'];
    final verifier = _verifier;
    _verifier = null;
    if (code == null || code.isEmpty || verifier == null) {
      _resolvePending(false);
      return;
    }
    try {
      final res = await _dio.post<dynamic>(
        Environment.mangabakaTokenUrl,
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'client_id': Environment.mangabakaClientId,
          'redirect_uri': Environment.mangabakaRedirectUri,
          // No client_secret: this is a public client. The discovery document
          // does not advertise `none` as a token-endpoint auth method, which
          // looks like an omission rather than a rule — if the exchange ever
          // fails with `invalid_client`, that is the thing to question first.
          'code_verifier': verifier,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final stored = await _storeTokens(res.data);
      await _nameFromIdToken(res.data);
      await _fetchUserInfo();
      if (!stored) {
        _resolvePending(false);
        return;
      }
      await _fetchViewer();
      notifyListeners();
      _resolvePending(true);
    } catch (_) {
      _resolvePending(false);
    }
  }

  /// Writes an access/refresh pair, returning false when the response carried
  /// no usable access token. [expires_in] is stored as an absolute deadline so
  /// a refresh can be decided without re-deriving it on every call.
  Future<bool> _storeTokens(dynamic data) async {
    if (data is! Map) return false;
    final token = data['access_token'];
    if (token is! String || token.isEmpty) return false;
    await _box.put('accessToken', token);
    final refresh = data['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) {
      await _box.put('refreshToken', refresh);
    }
    final expiresIn = data['expires_in'];
    if (expiresIn is int) {
      await _box.put(
        'expiresAt',
        DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
      );
    }
    return true;
  }

  /// The signed-in user's display name, taken from the OIDC `id_token`.
  ///
  /// `/v1/my/profile` has no avatar field and returns null names unless the
  /// user set one on the website, so the `name` claim is the only reliable
  /// source. Read locally — no signature check, because this is only a label:
  /// the token was just received over TLS from the token endpoint, and nothing
  /// is authorised on the strength of it.
  Future<void> _nameFromIdToken(dynamic tokenBody) async {
    if (tokenBody is! Map || tokenBody['id_token'] is! String) return;
    try {
      final parts = (tokenBody['id_token'] as String).split('.');
      if (parts.length != 3) return;
      final pad = '=' * ((4 - parts[1].length % 4) % 4);
      final claims = jsonDecode(utf8.decode(base64Url.decode(parts[1] + pad)));
      if (claims is! Map) return;
      final name = claims['name'] ?? claims['preferred_username'];
      if (name is String && name.isNotEmpty) {
        await _box.put('viewerName', name);
      }
    } catch (_) {
      // A malformed token must not fail the connect — the name is cosmetic.
    }
  }

  void _resolvePending(bool ok) {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete(ok);
  }

  /// The OIDC userinfo endpoint — the only place MangaBaka exposes an avatar.
  ///
  /// The discovery document lists `picture` (and `name`, `given_name`,
  /// `family_name`) under `claims_supported` and publishes
  /// `userinfo_endpoint`, but `/v1/my/profile` carries none of them and the
  /// id_token only carried `name`. Checking those two and concluding "this API
  /// has no avatar" was wrong — it was in the standard place all along.
  Future<void> _fetchUserInfo() async {
    try {
      final res = await _dio.get<dynamic>(
        'https://mangabaka.org/auth/oauth2/userinfo',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is! Map) return;
      final name = d['name'] ?? d['preferred_username'] ?? d['given_name'];
      if (name is String && name.isNotEmpty) {
        await _box.put('viewerName', name);
      }
      final pic = d['picture'];
      if (pic is String && pic.isNotEmpty) {
        await _box.put('viewerAvatar', pic);
      }
    } catch (_) {
      // Cosmetic: a failure here must not fail the connect.
    }
  }

  Future<void> _fetchViewer() async {
    try {
      final res = await _dio.get<dynamic>(
        '${Environment.mangabakaApi}/v1/my/profile',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      final user = (d is Map && d['data'] is Map) ? d['data'] as Map : d;
      if (user is! Map) return;
      // `/v1/my/profile` returns nickname and preferred_username, both null
      // unless the user set one, and NO avatar field at all — MangaBaka simply
      // does not expose one, so the row shows initials. The display name comes
      // from the id_token instead (see [_nameFromIdToken]); only overwrite it
      // here if the profile actually carries something.
      for (final k in const ['nickname', 'preferred_username', 'username']) {
        final v = user[k];
        if (v is String && v.isNotEmpty) {
          await _box.put('viewerName', v);
          break;
        }
      }
      // Last resort so the Connections row is never blank. The avatar and the
      // real name come from [_fetchUserInfo]; this only covers an account that
      // has set neither.
      if ((viewerName ?? '').isEmpty) {
        await _box.put('viewerName', 'MangaBaka account');
      }
    } catch (_) {}
  }

  @override
  Future<void> disconnect() async {
    final token = _box.get('accessToken') as String?;
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
    // Best-effort: tell MangaBaka to drop it too, so the app disappears from
    // the user's "Connected applications" list instead of lingering.
    if (token != null && token.isNotEmpty) {
      try {
        await _dio.post<dynamic>(
          Environment.mangabakaRevokeUrl,
          data: {'token': token, 'client_id': Environment.mangabakaClientId},
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            validateStatus: (s) => s != null && s < 500,
          ),
        );
      } catch (_) {}
    }
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${_box.get('accessToken') ?? ''}',
    'Accept': 'application/json',
  };

  // ── status mapping ───────────────────────────────────────────────────────

  /// MangaBaka's status strings ↔ [WatchStatus], in ONE place and both ways.
  ///
  /// All five spellings are confirmed against MangaBaka's published library
  /// states (`completed`, `considering`, `dropped`, `paused`, `plan_to_read`,
  /// `reading`, `rereading`). `statusFrom` still falls back rather than
  /// throwing, so an unknown state reads as planning instead of crashing.
  @visibleForTesting
  static const Map<WatchStatus, String> statusOut = {
    WatchStatus.planning: 'plan_to_read',
    WatchStatus.watching: 'reading',
    WatchStatus.completed: 'completed',
    WatchStatus.paused: 'paused',
    WatchStatus.dropped: 'dropped',
  };

  @visibleForTesting
  static WatchStatus statusFrom(Object? raw) {
    final v = '$raw'.toLowerCase().trim();
    return switch (v) {
      // `reading` and `plan_to_read` are confirmed from the live API (a row's
      // `state`, and the profile's `library_default_state`). The rest follow
      // the same snake_case shape; each spelling has an alias so a near-miss
      // still lands on the right status.
      'reading' || 'watching' || 'current' => WatchStatus.watching,
      'completed' || 'finished' || 'read' => WatchStatus.completed,
      'paused' || 'on_hold' || 'on-hold' => WatchStatus.paused,
      'dropped' => WatchStatus.dropped,
      // Anything unrecognised reads as "plan to read" rather than throwing:
      // an unknown status must never take down a whole library fetch.
      _ => WatchStatus.planning,
    };
  }

  // ── reads ────────────────────────────────────────────────────────────────

  @override
  Future<List<TrackerListItem>> fetchList() async {
    if (!isConnected) return const [];
    try {
      final res = await _dio.get<dynamic>(
        '${Environment.mangabakaApi}/v1/my/library',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (res.statusCode == 401) {
        await _onUnauthorized();
        return const [];
      }
      final d = res.data;
      final rows = (d is Map && d['data'] is List) ? d['data'] as List : null;
      if (rows == null) return const [];
      return [for (final r in rows) ?_itemFrom(r)];
    } catch (_) {
      return const [];
    }
  }

  /// One library row → [TrackerListItem]. Null for a row this build cannot
  /// read, so one odd entry costs that entry rather than the whole list.
  /// Field names are from the LIVE API, not from a schema — MangaBaka
  /// publishes none. A row looks like:
  ///
  ///   state=reading | progress_chapter=12 | progress_volume=2 | rating=80
  ///   id=2300879 | series_id=725 | Series={...} | start_date=... | note=...
  ///
  /// Note `Series` is capitalised and the status field is `state`; guessing
  /// the conventional spellings (`series`, `status`, `progress`, `score`) made
  /// every row fail to map, so the library rendered empty.
  TrackerListItem? _itemFrom(Object? raw) {
    if (raw is! Map) return null;
    final series = raw['Series'] is Map
        ? raw['Series'] as Map
        : (raw['series'] is Map ? raw['series'] as Map : null);
    if (series == null) return null;
    final id = series['id'] ?? raw['series_id'];
    if (id == null) return null;
    final title = '${series['title'] ?? ''}';
    if (title.isEmpty) return null;
    return TrackerListItem(
      item: MediaItem(
        // Shaped like the AniList rows on purpose: a `tracker:` id, no url and
        // no sourceId, and the cross-ids filled in. Carrying MangaBaka's own
        // url/sourceId instead left the app with no id to resolve, so opening
        // an entry fell back to searching by title.
        id: 'tracker:mangabaka:manga:$id',
        title: title,
        url: '',
        sourceId: '',
        // MangaBaka's own `type`: manga | manhwa | manhua | novel | other.
        // Only novel is a different ProviderType here; the three comic kinds
        // are all manga as far as this app is concerned.
        type: '${series['type']}'.toLowerCase() == 'novel'
            ? ProviderType.novel
            : ProviderType.manga,
        cover: _coverUrl(series['cover']),
        // Free, and the whole reason tapping can now land on the right title:
        // MangaBaka aggregates the other sites' ids for every series.
        malId: _sourceId(series, 'my_anime_list'),
        anilistId: _sourceId(series, 'anilist'),
      ),
      status: statusFrom(raw['state']),
      progress: raw['progress_chapter'] is num
          ? (raw['progress_chapter'] as num).round()
          : null,
      score: raw['rating'] is num ? ratingIn(raw['rating'] as num) : null,
      totalEpisodes: series['total_chapters'] is int
          ? series['total_chapters'] as int
          : null,
      updatedAt: DateTime.tryParse('${raw['start_date'] ?? ''}'),
    );
  }

  /// Poster URL from MangaBaka's nested cover object:
  ///
  ///   cover: { raw: {url, width, height}, x150: {x1,x2}, x250: …, x350: … }
  ///
  /// Prefer a CDN-resized variant — `raw` is the full scan (1800x2700, ~850KB
  /// for One Punch Man), which is wasteful for a list row.
  static String _coverUrl(Object? cover) {
    if (cover is String) return cover;
    if (cover is! Map) return '';
    for (final k in const ['x350', 'x250', 'x150']) {
      final v = cover[k];
      if (v is Map) {
        final u = v['x1'] ?? v['x2'];
        if (u is String && u.isNotEmpty) return u;
      }
    }
    final raw = cover['raw'];
    if (raw is Map && raw['url'] is String) return raw['url'] as String;
    return '';
  }

  /// Another site's id for this series, from MangaBaka's `source` block —
  /// `my_anime_list`, `anilist`, `kitsu`, `manga_updates`, `anime_planet`,
  /// `shikimori`. This is what makes a MangaBaka row resolvable to the same
  /// title everywhere else in the app.
  static int? _sourceId(Map series, String key) {
    final src = series['source'];
    if (src is! Map) return null;
    final entry = src[key];
    if (entry is! Map) return null;
    final id = entry['id'];
    return id is int ? id : int.tryParse('$id');
  }

  /// A 401 means the token died (revoked, or a refresh we have not implemented
  /// yet). Drop it so the UI offers Connect again rather than failing silently
  /// on every call from here on.
  Future<void> _onUnauthorized() async {
    await _box.delete('accessToken');
    notifyListeners();
  }

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    if (!isConnected || kind != MediaKind.manga) return null;
    final id = await _seriesIdFor(
      malId: malId,
      title: title,
      pinnedId: pinnedId,
      novel: novel,
    );
    if (id == null) return null;
    try {
      final res = await _dio.get<dynamic>(
        '${Environment.mangabakaApi}/v1/my/library/$id',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      // 404 here is not an error: it means "not in the library yet", which the
      // sheet renders as an empty entry rather than a failure.
      final row = (res.data is Map && res.data['data'] is Map)
          ? res.data['data'] as Map
          : null;
      if (row == null) return null;
      // The LIST route (`/v1/my/library`) embeds the series under `Series`,
      // capital S. This single-entry route does NOT embed it at all —
      // confirmed on device, its keys are: note, read_link, rating, state,
      // priority, is_private, number_of_rereads, progress_chapter,
      // progress_volume, start_date, finish_date, id, series_id, user_id,
      // Entries. So the title, chapter count and link have to be fetched
      // separately. It read as a blank "Matched:" line rather than an error,
      // which is why it went unnoticed.
      final series = row['Series'] is Map
          ? row['Series'] as Map
          : await _series(id);
      final seriesTitle = '${series?['title'] ?? ''}';
      if (seriesTitle.isEmpty) {
        debugPrint('[mb] entry $id still has no title; keys=${row.keys.toList()}');
      }
      return TrackerEntry(
        trackerName: displayName,
        onList: true,
        title: seriesTitle,
        status: statusFrom(row['state']),
        progress: row['progress_chapter'] is num
            ? (row['progress_chapter'] as num).round()
            : null,
        score: row['rating'] is num ? ratingIn(row['rating'] as num) : null,
        chapters: series?['total_chapters'] is int
            ? series!['total_chapters'] as int
            : null,
        url: '${series?['canonical_url'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// A series by id, from the PUBLIC catalogue route.
  ///
  /// Needed because `/v1/my/library/{id}` returns the entry alone — progress,
  /// state, rating — and names the series only by `series_id`. Cached for the
  /// session: the sync sheet reopens on the same handful of titles, and this
  /// is a plain catalogue read that cannot go stale in a way that matters.
  final Map<int, Map<dynamic, dynamic>> _seriesCache = {};

  Future<Map<dynamic, dynamic>?> _series(int id) async {
    final hit = _seriesCache[id];
    if (hit != null) return hit;
    try {
      final r = await _dio.get<dynamic>(
        '${Environment.mangabakaApi}/v1/series/$id',
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final d = (r.data is Map && r.data['data'] is Map)
          ? r.data['data'] as Map
          : null;
      if (d != null) _seriesCache[id] = d;
      return d;
    } catch (_) {
      return null;
    }
  }

  // ── resolution ───────────────────────────────────────────────────────────

  /// MangaBaka rates 0-100; this app's sheet is 0-10 ("$_score / 10").
  ///
  /// Confirmed on the live API — series 725 (ONE-PUNCH MAN) reads
  /// `rating: 86.62`, not 8.66 — and the published API client declares the
  /// library field as `minValue: 0, maxValue: 100`. An earlier comment here
  /// claimed the scales matched, so a 7 was written as 7/100 and a site score
  /// of 86 read back as "86 / 10".
  ///
  /// Both directions go through these two, deliberately: fixing one half alone
  /// is worse than the bug — write-only puts 86/10 on screen, read-only lands
  /// every new score at 0.8/10.
  static int ratingOut(double appScore) =>
      (appScore * 10).round().clamp(0, 100);

  static double ratingIn(num mangabakaRating) =>
      (mangabakaRating / 10).clamp(0, 10).toDouble();

  /// The MangaBaka series id for a title, or null when it cannot be resolved.
  ///
  /// [pinnedId] first: the user fixed this match by hand, and ignoring it is
  /// how a delete lands on the wrong entry. Then the MAL id, matched against
  /// the `source` block MangaBaka publishes for every series — exact, no
  /// string comparison. Title search is the last resort.
  ///
  /// There is no lookup-by-external-id endpoint (`/series/lookup`,
  /// `?my_anime_list=` and friends all 404 or reject the key), so the MAL path
  /// searches by title and then verifies the id. Verified, not assumed.
  Future<int?> _seriesIdFor({
    int? malId,
    String? title,
    String? pinnedId,
    bool novel = false,
  }) async {
    final pinned = int.tryParse(pinnedId ?? '');
    if (pinned != null) return pinned;
    final q = (title ?? '').trim();
    if (q.isEmpty) return null;
    try {
      final res = await _dio.get<dynamic>(
        '${Environment.mangabakaApi}/v1/series/search',
        queryParameters: {'q': q},
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final rows = (res.data is Map && res.data['data'] is List)
          ? res.data['data'] as List
          : const [];
      if (rows.isEmpty) return null;
      if (malId != null) {
        for (final r in rows) {
          if (r is Map && _sourceId(r, 'my_anime_list') == malId) {
            return r['id'] is int ? r['id'] as int : int.tryParse('${r['id']}');
          }
        }
        // A malId was given and nothing carried it: better no write than a
        // write onto a same-named different series.
        return null;
      }
      // No malId to verify against, so the `type` is the only thing keeping a
      // light novel apart from its own manga adaptation — plenty of series
      // exist as both, and writing a novel's progress onto the manga entry is
      // exactly the kind of silent wrong-entry write worth avoiding.
      final wanted = novel ? 'novel' : null;
      if (wanted != null) {
        for (final r in rows) {
          if (r is Map && '${r['type']}'.toLowerCase() == wanted) {
            return r['id'] is int ? r['id'] as int : int.tryParse('${r['id']}');
          }
        }
      }
      final first = rows.first;
      if (first is! Map) return null;
      return first['id'] is int
          ? first['id'] as int
          : int.tryParse('${first['id']}');
    } catch (_) {
      return null;
    }
  }

  /// One PATCH against `/v1/my/library/{seriesId}`, adding the series first
  /// if it is not on the list yet.
  ///
  /// The route is keyed by SERIES id, not by the library entry's own `id` —
  /// confirmed on device: the entry id returns
  /// `404 User do not have the requested series in their library`.
  ///
  /// PATCH only edits an entry that already exists, so a title the user has
  /// never added answers 404. The add is `POST /v1/my/library/batch` with a
  /// **bare JSON array** of rows — confirmed on a real account:
  /// `{"entries": [...]}` answers `400 expected array, received object`,
  /// the array answers 200. It creates and patches in the one request, so
  /// there is no second PATCH after it.
  Future<void> _patch(int seriesId, Map<String, dynamic> body) async {
    if (body.isEmpty || !isConnected) return;
    try {
      final r = await _dio.patch<dynamic>(
        '${Environment.mangabakaApi}/v1/my/library/$seriesId',
        data: body,
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (r.statusCode == 401) await _onUnauthorized();
      if (r.statusCode != 404) return;
      final add = await _dio.post<dynamic>(
        '${Environment.mangabakaApi}/v1/my/library/batch',
        data: [
          {'series_id': seriesId, ...body},
        ],
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      debugPrint('[mb] add $seriesId -> ${add.statusCode}');
    } catch (_) {
      // Best-effort, like every other tracker write.
    }
  }

  /// Reading-only: MangaBaka has no anime library, so an anime write here
  /// would have nowhere to land. Gated in one place rather than in each write.
  bool _canWrite(MediaKind kind) =>
      isConnected && kind == MediaKind.manga;

  // ── writes ───────────────────────────────────────────────────────────────

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!_canWrite(kind)) return;
    final id = await _seriesIdFor(malId: malId, title: title);
    if (id == null) return;
    await _patch(id, {'state': statusOut[WatchStatus.watching]!});
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
    bool novel = false,
  }) async {
    if (!_canWrite(kind)) return;
    final id = await _seriesIdFor(malId: malId, title: title, novel: novel);
    if (id == null) return;
    // `episode` is the chapter number for a reading kind — see the interface.
    await _patch(id, {
      'progress_chapter': episode,
      'state': statusOut[WatchStatus.watching]!,
    });
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
    if (!_canWrite(kind)) return;
    final id = await _seriesIdFor(malId: malId, title: title);
    if (id == null) return;
    await _patch(id, {'state': statusOut[status]!});
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
    if (!_canWrite(kind)) return;
    final id = await _seriesIdFor(malId: malId, title: title, pinnedId: pinnedId);
    if (id == null) return;
    // A null field is left unchanged (the interface says so), so only send
    // what actually changed.
    await _patch(id, {
      if (status != null) 'state': statusOut[status]!,
      'progress_chapter': ?progress,
      if (score != null) 'rating': ratingOut(score),
    });
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
    if (!_canWrite(kind)) return;
    final id = await _seriesIdFor(malId: malId, title: title, pinnedId: pinnedId);
    if (id == null) return;
    try {
      await _dio.delete<dynamic>(
        '${Environment.mangabakaApi}/v1/my/library/$id',
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
    } catch (_) {}
  }

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async {
    // Search is the one read that needs no token — /v1/series/search is public.
    if (query.trim().isEmpty) return const [];
    try {
      final res = await _dio.get<dynamic>(
        '${Environment.mangabakaApi}/v1/series/search',
        queryParameters: {'q': query.trim()},
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final d = res.data;
      final rows = (d is Map && d['data'] is List) ? d['data'] as List : null;
      if (rows == null) return const [];
      return [
        for (final r in rows)
          if (r is Map && r['id'] != null && '${r['title'] ?? ''}'.isNotEmpty)
            TrackerSearchResult(
              trackerName: 'MangaBaka',
              id: '${r['id']}',
              title: '${r['title']}',
              cover: r['cover'] is String ? r['cover'] as String : null,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  // ── session relay (TV) ───────────────────────────────────────────────────

  @override
  Map<String, dynamic>? exportSession() {
    final token = _box.get('accessToken') as String?;
    if (token == null || token.isEmpty) return null;
    return {
      'accessToken': token,
      'refreshToken': _box.get('refreshToken'),
      'expiresAt': _box.get('expiresAt'),
      'viewerName': _box.get('viewerName'),
      'viewerAvatar': _box.get('viewerAvatar'),
    };
  }

  @override
  Future<void> importSession(Map<String, dynamic> s) async {
    for (final k in const [
      'accessToken',
      'refreshToken',
      'expiresAt',
      'viewerName',
      'viewerAvatar',
    ]) {
      final v = s[k];
      if (v != null) await _box.put(k, v);
    }
    notifyListeners();
  }
}
