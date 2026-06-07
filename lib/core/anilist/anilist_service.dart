import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../environment.dart';
import '../models/watch_status.dart';
import '../tracker/tracker.dart';
import '../ui/global_messenger.dart';
import 'anilist_api.dart';
import 'anilist_store.dart';

/// Outcome of a single scrobble attempt.
enum _Scrobble { synced, skipped, unmatched, failed }

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

  /// Resolve an AniList `(mediaId, total episodes)` from a MAL id (cached).
  Future<({int id, int? total})?> _resolveByMal(int malId) async {
    final cached = _store.cachedMediaId(malId);
    if (cached != null) {
      return (id: cached, total: _store.cachedEpisodes(cached));
    }
    final m = await _api.mediaByMalId(malId);
    if (m == null) return null;
    await _store.cacheMediaId(malId, m.id);
    if (m.episodes != null) await _store.cacheEpisodes(m.id, m.episodes!);
    return (id: m.id, total: m.episodes);
  }

  /// Resolve by anime title via AniList search (cached). Used when the provider
  /// didn't supply a MAL id (old provider / AllAnime), so scrobbling never
  /// depends on a provider update.
  Future<({int id, int? total})?> _resolveByTitle(String title) async {
    final key = title.trim().toLowerCase();
    if (key.isEmpty) return null;
    final cached = _store.cachedMediaIdByTitle(key);
    if (cached != null) {
      return (id: cached, total: _store.cachedEpisodes(cached));
    }
    final m = await _api.mediaBySearch(title);
    if (m == null) return null;
    await _store.cacheMediaIdByTitle(key, m.id);
    if (m.episodes != null) await _store.cacheEpisodes(m.id, m.episodes!);
    return (id: m.id, total: m.episodes);
  }

  /// MAL id first (exact), then title search (fallback).
  Future<({int id, int? total})?> _resolveMedia(int? malId, String? title) async {
    if (malId != null) {
      final m = await _resolveByMal(malId);
      if (m != null) return m;
    }
    if (title != null && title.trim().isNotEmpty) {
      return _resolveByTitle(title);
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
  }) async {
    if (!isConnected || !autoSync || episode <= 0) return;
    if (malId == null && (title == null || title.trim().isEmpty)) return;
    final r = await _scrobbleResolved(malId: malId, title: title, episode: episode);
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
  }) async {
    final media = await _resolveMedia(malId, title);
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
      await _store.removePending(malId: malId, title: title);
      return _Scrobble.synced;
    }
    await _store.queueScrobble(malId: malId, title: title, episode: episode);
    return _Scrobble.failed;
  }

  /// Retry any queued scrobbles (called on launch + after connect). Silent.
  Future<void> flushPending() async {
    if (!isConnected) return;
    for (final p in _store.pendingScrobbles) {
      final episode = p['episode'] as int?;
      if (episode == null) continue;
      final r = await _scrobbleResolved(
        malId: p['malId'] as int?,
        title: p['title'] as String?,
        episode: episode,
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
  }) async {
    if (!isConnected) return;
    final media = await _resolveMedia(malId, title);
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
  }) async {
    if (!isConnected || !autoSync) return;
    if (malId == null && (title == null || title.trim().isEmpty)) return;
    final media = await _resolveMedia(malId, title);
    if (media == null) return;
    final total = media.total;
    if (total != null && total > 0 &&
        _store.scrobbledProgress(media.id) >= total) {
      return; // already completed — don't downgrade to Watching
    }
    final ok = await _api.saveStatus(mediaId: media.id, status: 'CURRENT');
    debugPrint('[AniList] markWatching (mal=$malId title="$title") -> $ok');
  }

  /// Remove an anime from the user's AniList list (when removed from My List).
  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
  }) async {
    if (!isConnected) return;
    final media = await _resolveMedia(malId, title);
    if (media == null) return;
    await _api.deleteEntry(media.id);
    await _store.setScrobbledProgress(media.id, 0);
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }
}
