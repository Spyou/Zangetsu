import 'package:flutter/foundation.dart';

import '../models/watch_status.dart';

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
  /// identified by [malId]/[title]; movies/series by [tmdbId] (+ [tmdbIsTv]).
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
  });

  /// Record that [episode] was watched (for a movie, episode is ignored).
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    required int episode,
  });

  /// Set an explicit library status (from the "Add to List" sheet).
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
    required WatchStatus status,
  });

  /// Remove the title from the user's list.
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv,
  });
}
