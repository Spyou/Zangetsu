import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../models/watch_status.dart';

/// One entry of the user's library read back from a tracker (AniList/MAL/Simkl).
/// [item] is a METADATA STUB — title/cover/ids only, with `url`/`sourceId` empty
/// (no provider is attached; a playable source is resolved by title on tap).
class TrackerListItem {
  const TrackerListItem({
    required this.item,
    required this.status,
    this.progress,
    this.score,
  });

  final MediaItem item;
  final WatchStatus status; // planning | watching | completed | paused | dropped
  final int? progress; // episodes watched (optional, for display)
  final double? score; // user score 0–10 (optional, for display)
}

/// A list/progress tracker the app can sync to (AniList, MyAnimeList, Simkl).
/// All write ops are best-effort and self-gating — a disconnected tracker (or
/// one with auto-sync off, or a non-applicable content type) simply no-ops.
/// [Listenable] so settings rebuild on connect/disconnect.
abstract interface class Tracker implements Listenable {
  /// Human label, e.g. "AniList".
  String get displayName;

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
  /// failing that, [imdbId] (Simkl accepts an imdb id).
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
  });

  /// Record that [episode] was watched (for a movie, episode is ignored).
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    required int episode,
  });

  /// Set an explicit library status (from the "Add to List" sheet).
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
    required WatchStatus status,
  });

  /// Remove the title from the user's list.
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    String? imdbId,
  });

  /// Read back the user's full library from this tracker (anime; Simkl may also
  /// include movies/TV). Best-effort: returns `[]` when disconnected or on any
  /// error — never throws. Each item is a metadata stub + its library status.
  Future<List<TrackerListItem>> fetchList();
}
