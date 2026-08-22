import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../models/watch_status.dart';

/// Which list a tracker write/read targets. Anime covers today's anime +
/// movie/TV app unchanged. Novels map to [manga] at this boundary — AniList
/// and MyAnimeList both file light novels under their manga list (there is no
/// separate novel list to target), so a third value here would be a lie.
enum MediaKind { anime, manga }

/// Parse a persisted [MediaKind] name (e.g. from a Hive-stored queue entry).
/// Null/unknown → [MediaKind.anime] — the same default every kind-aware
/// method in this file already has, and what every entry written before this
/// parameter existed implicitly meant.
MediaKind mediaKindFromName(String? name) =>
    name == MediaKind.manga.name ? MediaKind.manga : MediaKind.anime;

/// One entry of the user's library read back from a tracker (AniList/MAL/Simkl).
/// [item] is a METADATA STUB — title/cover/ids only, with `url`/`sourceId` empty
/// (no provider is attached; a playable source is resolved by title on tap).
class TrackerListItem {
  const TrackerListItem({
    required this.item,
    required this.status,
    this.progress,
    this.score,
    this.tmdbIsTv = false,
  });

  final MediaItem item;
  final WatchStatus status; // planning | watching | completed | paused | dropped
  final int? progress; // episodes watched (optional, for display)
  final double? score; // user score 0–10 (optional, for display)

  /// For non-anime entries resolved by TMDB id (Simkl movies/TV): whether this
  /// is a TV show, so writes go to the right bucket. Ignored for anime.
  final bool tmdbIsTv;
}

/// The user's current entry for ONE title, read back from a tracker to fill the
/// sync sheet. Any field may be null when the tracker doesn't expose it.
class TrackerEntry {
  const TrackerEntry({
    required this.trackerName,
    this.onList = false,
    this.title,
    this.status,
    this.score,
    this.progress,
    this.maxEpisodes,
    this.chapters,
    this.nextAiringEpisode,
    this.nextAiringAt,
    this.url,
  });

  /// Which tracker this came from, e.g. "AniList".
  final String trackerName;

  /// Whether the title is on the user's list at all.
  final bool onList;

  /// What this tracker actually matched, so the sheet can show it and the user
  /// can tell a wrong auto-match from a right one. Null when the tracker can't
  /// supply it — the row then reads as unmatched rather than guessing.
  final String? title;

  /// This entry's page on the tracker's own site, for "Open in browser" /
  /// "Copy link". Null when the tracker didn't resolve a match (nothing to
  /// link to) — the menu greys those actions out rather than opening a
  /// half-built url.
  final String? url;

  final WatchStatus? status;

  /// User score on a 0–10 scale (null/0 = unrated).
  final double? score;

  /// Progress — episodes watched for [MediaKind.anime], chapters read for
  /// [MediaKind.manga].
  final int? progress;

  /// Total episodes (null/0 = unknown or a movie). Anime only.
  final int? maxEpisodes;

  /// Total chapters (null/0 = unknown or ongoing). Manga/novel only.
  final int? chapters;

  /// The next episode to air + when, while the show is still airing.
  final int? nextAiringEpisode;
  final DateTime? nextAiringAt;
}

/// A candidate match from a tracker's search — used by the "fix wrong match"
/// picker to rebind a show to the correct tracker entry.
class TrackerSearchResult {
  const TrackerSearchResult({
    required this.trackerName,
    required this.id,
    required this.title,
    this.cover,
    this.subtitle,
    this.maxEpisodes,
  });

  final String trackerName;

  /// The tracker-native id, as a string (AniList media id / MAL anime id /
  /// Simkl id). Persisted as a pinned binding and passed back as `pinnedId`.
  final String id;
  final String title;
  final String? cover;

  /// A short line under the title (format · year), for disambiguation.
  final String? subtitle;
  final int? maxEpisodes;
}

/// A list/progress tracker the app can sync to (AniList, MyAnimeList, Simkl).
/// All write ops are best-effort and self-gating — a disconnected tracker (or
/// one with auto-sync off, or a non-applicable content type) simply no-ops.
/// [Listenable] so settings rebuild on connect/disconnect.
abstract interface class Tracker implements Listenable {
  /// Human label, e.g. "AniList".
  String get displayName;

  /// Whether this tracker has a manga/novel library at all. False for Simkl,
  /// which is video-only — its write paths already no-op on [MediaKind.manga].
  /// The UI uses this to hide inapplicable trackers in a reading mode instead
  /// of offering an account that can never sync anything there.
  bool get supportsReading;

  bool get isConnected;
  String? get viewerName;
  String? get viewerAvatar;

  bool get autoSync;
  set autoSync(bool value);

  /// Open the OAuth flow; resolves true once linked.
  Future<bool> connect();
  Future<void> disconnect();

  /// Mark a title as currently-watching (called when playback starts). Anime is
  /// identified by [malId]/[title]; movies/series by [tmdbId] (+ [tmdbIsTv]) or,
  /// failing that, [imdbId] (Simkl accepts an imdb id). [kind] selects which
  /// list this targets (anime vs. manga/novel); defaults to anime so every
  /// existing call site is unaffected.
  ///
  /// [kind] carries its default HERE, at the interface, unlike the equally-
  /// bare-looking [tmdbIsTv] below (no default, no `required`): every call
  /// site that reaches this method through a concrete class (TrackerHub,
  /// SimklService, ...) already passes tmdbIsTv explicitly, but
  /// tracker_entry_sheet.dart calls through a bare `Tracker`-typed variable
  /// and never passes `kind:`. `MediaKind` is non-nullable, so that call only
  /// type-checks because the interface itself supplies the default — don't
  /// "clean this up" to match tmdbIsTv, it'll stop compiling.
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  });

  /// Record that [episode] was watched (for a movie, episode is ignored). For
  /// [MediaKind.manga], [episode] is the chapter number.
  ///
  /// [novel] narrows a title-search resolution to light novels specifically —
  /// AniList files novels under [MediaKind.manga] too (`format: NOVEL`), so
  /// without this a novel with no [malId] resolves against its franchise's
  /// manga entry instead of its own. Ignored outside AniList; ignored by
  /// [malId]-based resolution (unambiguous there already).
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    required int episode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  });

  /// Set an explicit library status (from the "Add to List" sheet).
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  });

  /// Remove the title from the user's list.
  ///
  /// [pinnedId] behaves as it does in [fetchEntry]: when the user has fixed a
  /// wrong match by hand, it overrides malId/title resolution. Passing it
  /// MATTERS here — without it a corrected match resolves back to the entry
  /// the app originally guessed, and the delete lands on the wrong title in
  /// the user's list.
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  });

  /// Read back the user's full library from this tracker (anime; Simkl may also
  /// include movies/TV). Best-effort: returns `[]` when disconnected or on any
  /// error — never throws. Each item is a metadata stub + its library status.
  Future<List<TrackerListItem>> fetchList();

  /// Read the user's current entry for ONE title — status/score/progress plus
  /// the title's total episodes and next airing — to populate the sync sheet.
  /// Best-effort: null when disconnected, unmatched, or on any error. When
  /// [pinnedId] is supplied (a tracker-native id chosen via the match-fixer) it
  /// overrides the malId/title/tmdb resolution. [novel] — see [scrobble].
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  });

  /// Write status/score/progress together for ONE title (the sync sheet's
  /// Apply). A null field is left unchanged. [score] is 0–10. Best-effort and
  /// self-gating like every other write.
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
  });

  /// Search this tracker for candidate matches (the match-fixer). Returns `[]`
  /// when disconnected, the query is empty, or on any error — never throws.
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  });

  /// The full persisted session as a plain JSON-able map, or null if not
  /// connected. Used by the TV relay to move a session between devices.
  Map<String, dynamic>? exportSession();

  /// Write a relayed [session] (shape produced by [exportSession]) into local
  /// storage and refresh state (`notifyListeners`).
  Future<void> importSession(Map<String, dynamic> session);
}
