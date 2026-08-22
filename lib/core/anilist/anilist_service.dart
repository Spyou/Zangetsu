import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../environment.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../tracker/tracker.dart';
import '../ui/global_messenger.dart';
import 'anilist_api.dart';
import 'anilist_store.dart';

/// Outcome of a single scrobble attempt.
enum _Scrobble { synced, skipped, unmatched, failed }

/// Which [ProviderType] an AniList media of [kind] with this `format` belongs
/// to. AniList has no novel *type* — light novels live on the MANGA list and
/// are only distinguishable by `format: NOVEL`, so without this split every
/// novel would land in manga mode and novel mode would look empty.
///
/// Anything else on the manga list (`MANGA`, `ONE_SHOT`, a format we don't
/// know, or a null when the field wasn't selected) is treated as manga — a
/// wrong-but-visible bucket beats a silently dropped entry.
ProviderType aniListProviderType(MediaKind kind, String? format) {
  if (kind != MediaKind.manga) return ProviderType.anime;
  return format == 'NOVEL' ? ProviderType.novel : ProviderType.manga;
}

/// Parse a `MediaListCollection` response into library stubs. Pure + top-level
/// so a test can feed it a recorded response without a live API.
///
/// The malId dedupe set is per-call ON PURPOSE: MAL's anime and manga id
/// spaces overlap (anime 21 and manga 21 are different titles), so sharing one
/// set across kinds would silently swallow manga entries.
List<TrackerListItem> parseAniListCollection(Object? data, MediaKind kind) {
  final collection = (data is Map && data['data'] is Map)
      ? (data['data'] as Map)['MediaListCollection']
      : null;
  final lists = (collection is Map) ? collection['lists'] : null;
  if (lists is! List) return const [];

  final out = <TrackerListItem>[];
  final seen = <int>{}; // dedupe by malId
  var idx = 0;
  for (final list in lists) {
    final entries = (list is Map) ? list['entries'] : null;
    if (entries is! List) continue;
    for (final e in entries) {
      if (e is! Map) continue;
      final status = watchStatusFromAniList(e['status'] as String?);
      if (status == null) continue;
      final media = e['media'];
      if (media is! Map) continue;
      final malId = (media['idMal'] as num?)?.toInt();
      if (malId != null && !seen.add(malId)) continue; // already have it

      final t = media['title'];
      final english = (t is Map) ? t['english'] as String? : null;
      final romaji = (t is Map) ? t['romaji'] as String? : null;
      final title = (english?.isNotEmpty == true)
          ? english!
          : (romaji ?? 'Unknown');
      final cover = (media['coverImage'] is Map)
          ? (media['coverImage'] as Map)['large'] as String?
          : null;

      final rawScore = (e['score'] as num?)?.toDouble();
      final score = (rawScore == null || rawScore == 0) ? null : rawScore;

      // Reading kinds get their own id namespace for the same id-space-overlap
      // reason as `seen`; anime keeps the original, unprefixed id.
      final key = malId ?? idx;
      out.add(TrackerListItem(
        item: MediaItem(
          id: kind == MediaKind.manga
              ? 'tracker:anilist:manga:$key'
              : 'tracker:anilist:$key',
          title: title,
          cover: cover,
          url: '',
          type: aniListProviderType(kind, media['format'] as String?),
          sourceId: '',
          malId: malId,
        ),
        status: status,
        // Chapters read for a reading kind, episodes watched for anime —
        // AniList uses the one `progress` field for both.
        progress: (e['progress'] as num?)?.toInt(),
        score: score,
      ));
      idx++;
    }
  }
  return out;
}

/// Facade for the AniList integration. Owns the OAuth connect flow (browser +
/// deep-link capture), the persisted session, and the auto-scrobbler. A
/// [ChangeNotifier] so the settings UI rebuilds on connect/disconnect.
class AniListService extends ChangeNotifier implements Tracker {
  AniListService(this._dio) {
    _store = AniListStore();
    _api = AniListApi(_dio, () => _store.token);
    _linkSub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    // Cover the cold-start case (browser relaunched the app with the redirect).
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _onLink(uri);
    }).catchError((_) {});
  }

  final Dio _dio;
  late final AniListStore _store;
  late final AniListApi _api;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Completer<bool>? _pending;

  AniListApi get api => _api;
  AniListStore get store => _store;

  @override
  String get displayName => 'AniList';

  @override
  bool get supportsReading => true; // AniList has manga + light novels

  @override
  bool get isConnected => _store.hasValidToken && _store.viewerId != null;
  @override
  String? get viewerName => _store.viewerName;
  @override
  String? get viewerAvatar => _store.viewerAvatar;

  @override
  bool get autoSync => _store.autoSync;
  @override
  set autoSync(bool v) {
    _store.autoSync = v;
    notifyListeners();
  }

  // ── OAuth connect ───────────────────────────────────────────────────────────

  void _onLink(Uri uri) {
    if (uri.scheme != Environment.anilistRedirectScheme ||
        uri.host != Environment.anilistRedirectHost) {
      return;
    }
    _handleRedirect(uri);
  }

  Future<void> _handleRedirect(Uri uri) async {
    // Implicit grant returns the token in the URL fragment:
    //   zangetsu://anilist-auth#access_token=...&token_type=Bearer&expires_in=NNN
    final params = Uri.splitQueryString(uri.fragment);
    final token = params['access_token'];
    if (token == null || token.isEmpty) {
      _resolvePending(false);
      return;
    }
    final expiresIn = int.tryParse(params['expires_in'] ?? '') ?? 0;
    final expiresAt = expiresIn > 0
        ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
        : 0;
    await _store.saveSession(token: token, expiresAt: expiresAt);

    final v = await _api.viewer();
    if (v == null) {
      await _store.clearSession(); // token didn't actually work
      notifyListeners();
      _resolvePending(false);
      return;
    }
    await _store.saveViewer(id: v.id, name: v.name, avatar: v.avatar);
    notifyListeners();
    _resolvePending(true);
    flushPending(); // push anything that queued while disconnected/offline
  }

  void _resolvePending(bool ok) {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete(ok);
  }

  /// Open AniList consent in the browser. Resolves true once the redirect comes
  /// back with a valid token and the viewer is fetched; false on cancel/timeout.
  @override
  Future<bool> connect() async {
    final authUrl = Uri.parse(
      'https://anilist.co/api/v2/oauth/authorize'
      '?client_id=${Environment.anilistClientId}&response_type=token',
    );
    _pending = Completer<bool>();
    final launched = await launchUrl(
      authUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
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

  @override
  Future<void> disconnect() async {
    await _store.clearSession();
    notifyListeners();
  }

  // ── Media resolution (MAL id, else title search) ────────────────────────────

  /// Resolve an AniList `(mediaId, total episodes/chapters)` from a MAL id
  /// (cached). The id cache is namespaced by [kind] — MAL's anime and manga
  /// id spaces overlap, so a malId that collided between the two would
  /// otherwise return a stale cross-kind hit.
  Future<({int id, int? total})?> _resolveByMal(
    int malId, [
    MediaKind kind = MediaKind.anime,
  ]) async {
    final cached = _store.cachedMediaId(malId, kind);
    if (cached != null) {
      return (id: cached, total: _store.cachedEpisodes(cached, kind));
    }
    final m = await _api.mediaByMalId(malId, kind: kind);
    if (m == null) return null;
    await _store.cacheMediaId(malId, m.id, kind);
    if (m.episodes != null) await _store.cacheEpisodes(m.id, m.episodes!, kind);
    return (id: m.id, total: m.episodes);
  }

  /// Resolve by title via AniList search (cached). Used when the provider
  /// didn't supply a MAL id (old provider / AllAnime), so scrobbling never
  /// depends on a provider update.
  ///
  /// [novel] narrows the search to `format: NOVEL` — plain [MediaKind.manga]
  /// search picks the top MANGA-or-novel result, which for a light novel is
  /// almost always the wrong (franchise manga) entry. The cache key is
  /// 'novel:'-prefixed so a novel and a same-titled manga never collide in
  /// the shared title→id map.
  Future<({int id, int? total})?> _resolveByTitle(
    String title, [
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  ]) async {
    final trimmed = title.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final key = novel ? 'novel:$trimmed' : trimmed;
    final cached = _store.cachedMediaIdByTitle(key, kind);
    if (cached != null) {
      return (id: cached, total: _store.cachedEpisodes(cached, kind));
    }
    ({int id, int? episodes})? m;
    if (novel) {
      final results = await _api.searchMedia(
        title,
        kind: kind,
        novelFormat: true,
        perPage: 1,
      );
      final top = results.isEmpty ? null : results.first;
      m = top == null
          ? null
          : (
              id: (top['id'] as num).toInt(),
              episodes: (top['chapters'] as num?)?.toInt(),
            );
    } else {
      m = await _api.mediaBySearch(title, kind: kind);
    }
    if (m == null) return null;
    await _store.cacheMediaIdByTitle(key, m.id, kind);
    if (m.episodes != null) await _store.cacheEpisodes(m.id, m.episodes!, kind);
    return (id: m.id, total: m.episodes);
  }

  /// MAL id first (exact), then title search (fallback). [novel] only affects
  /// the title-search fallback — a [malId] hit is already unambiguous.
  Future<({int id, int? total})?> _resolveMedia(
    int? malId,
    String? title, [
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  ]) async {
    if (malId != null) {
      final m = await _resolveByMal(malId, kind);
      if (m != null) return m;
    }
    if (title != null && title.trim().isNotEmpty) {
      return _resolveByTitle(title, kind, novel);
    }
    return null;
  }

  // ── Scrobbling ──────────────────────────────────────────────────────────────

  /// Push that [episode] of an anime was watched. Identify it by [malId] (exact)
  /// or [title] (fallback). Sets status CURRENT (or COMPLETED at the finale),
  /// never moves progress backwards, de-dupes via a high-water mark, and queues
  /// failures for retry. No-op when disconnected or auto-sync is off.
  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    if (!isConnected || !autoSync || episode <= 0) return;
    if (malId == null && (title == null || title.trim().isEmpty)) return;
    final r = await _scrobbleResolved(
      malId: malId,
      title: title,
      episode: episode,
      kind: kind,
      novel: novel,
    );
    debugPrint('[AniList] scrobble ep$episode (mal=$malId title="$title") -> $r');
    // Stay silent on success — only surface a real failure (so a sync can't
    // break unnoticed). Unmatched/skipped are quiet too.
    if (r == _Scrobble.failed) {
      showGlobalSnack('AniList sync failed — will retry');
    }
  }

  Future<_Scrobble> _scrobbleResolved({
    int? malId,
    String? title,
    required int episode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    final media = await _resolveMedia(malId, title, kind, novel);
    if (media == null) {
      debugPrint('[AniList] no AniList match for mal=$malId title="$title"');
      return _Scrobble.unmatched;
    }
    final mediaId = media.id;
    final total = media.total;

    if (episode <= _store.scrobbledProgress(mediaId)) return _Scrobble.skipped;

    var progress = episode;
    if (total != null && total > 0 && progress > total) progress = total;
    final status = (total != null && total > 0 && progress >= total)
        ? 'COMPLETED'
        : 'CURRENT';

    final ok = await _api.saveProgress(
      mediaId: mediaId,
      progress: progress,
      status: status,
    );
    if (ok) {
      await _store.setScrobbledProgress(mediaId, progress);
      await _store.removePending(
        malId: malId,
        title: title,
        kind: kind,
        novel: novel,
      );
      return _Scrobble.synced;
    }
    await _store.queueScrobble(
      malId: malId,
      title: title,
      episode: episode,
      kind: kind,
      novel: novel,
    );
    return _Scrobble.failed;
  }

  /// Retry any queued scrobbles (called on launch + after connect). Silent.
  /// Replays each row against ITS OWN [MediaKind] (a manga scrobble that
  /// failed offline must replay as manga, not silently default to anime —
  /// [mediaKindFromName] reads a pre-kind-field row as anime, same as before)
  /// and its own [novel] bit — a novel that failed offline must resolve by
  /// the format:NOVEL search again, not fall back to plain manga.
  Future<void> flushPending() async {
    if (!isConnected) return;
    for (final p in _store.pendingScrobbles) {
      final episode = p['episode'] as int?;
      if (episode == null) continue;
      final r = await _scrobbleResolved(
        malId: p['malId'] as int?,
        title: p['title'] as String?,
        episode: episode,
        kind: mediaKindFromName(p['kind'] as String?),
        novel: p['novel'] as bool? ?? false,
      );
      if (r == _Scrobble.failed) break; // still offline — retry next time
    }
  }

  // ── List status (from the "Add to List" sheet) ──────────────────────────────

  /// Set the AniList list status for an anime ([malId] or [title]). COMPLETED
  /// also pushes progress to the total. Best-effort.
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
    final media = await _resolveMedia(malId, title, kind);
    if (media == null) return;
    if (status == WatchStatus.completed &&
        media.total != null &&
        media.total! > 0) {
      final ok = await _api.saveProgress(
        mediaId: media.id,
        progress: media.total!,
        status: 'COMPLETED',
      );
      if (ok) await _store.setScrobbledProgress(media.id, media.total!);
    } else {
      await _api.saveStatus(mediaId: media.id, status: status.anilist);
    }
  }

  /// Mark an anime as CURRENT (Watching) the moment playback starts — so it
  /// appears on AniList immediately, before any episode crosses the 92% scrobble
  /// threshold. Does not touch progress (the per-episode scrobbler owns that)
  /// and won't flip an already-completed title back to Watching on a re-open.
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
    if (malId == null && (title == null || title.trim().isEmpty)) return;
    final media = await _resolveMedia(malId, title, kind);
    if (media == null) return;
    final total = media.total;
    if (total != null && total > 0 &&
        _store.scrobbledProgress(media.id) >= total) {
      return; // already completed — don't downgrade to Watching
    }
    final ok = await _api.saveStatus(mediaId: media.id, status: 'CURRENT');
    debugPrint('[AniList] markWatching (mal=$malId title="$title") -> $ok');
  }

  // ── Library read-back (for the My List tracker switcher) ────────────────────

  /// Read the connected user's full AniList library as metadata stubs +
  /// status — the anime list AND the manga list (which is where AniList keeps
  /// light novels too; [parseAniListCollection] splits them back out).
  /// Best-effort: `[]` when disconnected or on ANY error (never throws).
  @override
  Future<List<TrackerListItem>> fetchList() async {
    final user = _store.viewerName;
    if (!isConnected || user == null || user.isEmpty) return const [];
    // Each kind is fetched + caught independently, so a failing manga read
    // can't take the anime list down with it.
    final both = await Future.wait([
      _fetchListOf(MediaKind.anime, user),
      _fetchListOf(MediaKind.manga, user),
    ]);
    return [...both[0], ...both[1]];
  }

  Future<List<TrackerListItem>> _fetchListOf(MediaKind kind, String user) async {
    try {
      final res = await _dio.post<dynamic>(
        'https://graphql.anilist.co',
        data: {
          'query': mediaListCollectionQuery(kind),
          'variables': {'u': user},
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer ${_store.token}',
          },
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      return parseAniListCollection(res.data, kind);
    } catch (_) {
      return const [];
    }
  }

  /// Remove an anime from the user's AniList list (when removed from My List).
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
    final mediaId = int.tryParse(pinnedId ?? '') ??
        (await _resolveMedia(malId, title, kind))?.id;
    if (mediaId == null) return;
    await _api.deleteEntry(mediaId);
    await _store.setScrobbledProgress(mediaId, 0);
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
    bool novel = false,
  }) async {
    if (!isConnected) return null;
    final mediaId =
        int.tryParse(pinnedId ?? '') ??
        (await _resolveMedia(malId, title, kind, novel))?.id;
    if (mediaId == null) return null;
    final m = await _api.mediaEntry(mediaId, kind: kind);
    if (m == null) return null;
    final entry = m['mediaListEntry'];
    final na = m['nextAiringEpisode'];
    final airAt = (na is Map) ? (na['airingAt'] as num?)?.toInt() : null;
    final rawScore =
        (entry is Map) ? (entry['score'] as num?)?.toDouble() : null;
    final t = m['title'];
    final tEnglish = (t is Map) ? t['english'] as String? : null;
    final tRomaji = (t is Map) ? t['romaji'] as String? : null;
    return TrackerEntry(
      trackerName: displayName,
      onList: entry is Map,
      url: 'https://anilist.co/'
          '${kind == MediaKind.manga ? 'manga' : 'anime'}/$mediaId',
      // English first, romaji second — the same order the search picker uses,
      // so a row and its match candidates read the same way.
      title: (tEnglish?.isNotEmpty == true) ? tEnglish : tRomaji,
      status: (entry is Map)
          ? watchStatusFromAniList(entry['status'] as String?)
          : null,
      score: (rawScore == null || rawScore == 0) ? null : rawScore,
      progress: (entry is Map) ? (entry['progress'] as num?)?.toInt() : null,
      // Only one of these two is ever selected by the query per [kind], so
      // the field that wasn't asked for is simply absent from the response.
      maxEpisodes: (m['episodes'] as num?)?.toInt(),
      chapters: (m['chapters'] as num?)?.toInt(),
      nextAiringEpisode: (na is Map) ? (na['episode'] as num?)?.toInt() : null,
      nextAiringAt: airAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(airAt * 1000),
    );
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
    final mediaId =
        int.tryParse(pinnedId ?? '') ??
        (await _resolveMedia(malId, title, kind))?.id;
    if (mediaId == null) return;
    final ok = await _api.saveEntry(
      mediaId: mediaId,
      status: status?.anilist,
      progress: progress,
      scoreRaw: score == null ? null : (score * 10).round().clamp(0, 100),
    );
    // Keep the scrobbler's high-water mark in step with a manual progress edit,
    // so auto-scrobble won't later "undo" it or re-push an older episode.
    if (ok && progress != null) {
      await _store.setScrobbledProgress(mediaId, progress);
    }
  }

  /// [novelFormat] narrows a [MediaKind.manga] search to light novels only
  /// (`format_in: [NOVEL]`) — not part of the [Tracker] interface, so it's
  /// only reachable by callers holding a concrete [AniListService]. Ignored
  /// for anime.
  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
    bool novelFormat = false,
  }) async {
    if (query.trim().isEmpty) return const [];
    final results = await _api.searchMedia(
      query,
      kind: kind,
      novelFormat: novelFormat,
    );
    return [
      for (final m in results)
        TrackerSearchResult(
          trackerName: displayName,
          id: '${m['id']}',
          title: _bestTitle(m['title']),
          cover: (m['coverImage'] is Map)
              ? (m['coverImage'] as Map)['medium'] as String?
              : null,
          subtitle: _searchSubtitle(m),
          maxEpisodes: (m['episodes'] as num?)?.toInt(),
        ),
    ];
  }

  static String _bestTitle(Object? t) {
    if (t is! Map) return 'Unknown';
    final english = t['english'] as String?;
    final romaji = t['romaji'] as String?;
    return (english?.isNotEmpty == true) ? english! : (romaji ?? 'Unknown');
  }

  static String? _searchSubtitle(Map m) {
    final format = (m['format'] as String?)?.replaceAll('_', ' ');
    final year = (m['seasonYear'] as num?)?.toInt();
    final parts = [
      if (format != null && format.isNotEmpty) format,
      if (year != null) '$year',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  // ── Session export/import (TV relay) ────────────────────────────────────

  @override
  Map<String, dynamic>? exportSession() => _store.exportSession();

  @override
  Future<void> importSession(Map<String, dynamic> session) async {
    await _store.importSession(session);
    notifyListeners();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }
}
