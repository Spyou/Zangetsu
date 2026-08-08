/// A title's place in the user's library — the same set AniList / MAL / Simkl
/// use. Stored locally (and pushed to AniList for anime). Used to organise My
/// List and drive the "Add to List" status sheet.
enum WatchStatus { planning, watching, completed, paused, dropped }

extension WatchStatusX on WatchStatus {
  /// Persisted key (the enum name).
  String get key => name;

  /// Human label for the sheet + section headers.
  String get label => switch (this) {
    WatchStatus.planning => 'Plan to Watch',
    WatchStatus.watching => 'Watching',
    WatchStatus.completed => 'Completed',
    WatchStatus.paused => 'Paused',
    WatchStatus.dropped => 'Dropped',
  };

  /// Short label for filter chips / section headers.
  String get shortLabel => switch (this) {
    WatchStatus.planning => 'Planning',
    WatchStatus.watching => 'Watching',
    WatchStatus.completed => 'Completed',
    WatchStatus.paused => 'Paused',
    WatchStatus.dropped => 'Dropped',
  };

  /// AniList `MediaListStatus` value.
  String get anilist => switch (this) {
    WatchStatus.planning => 'PLANNING',
    WatchStatus.watching => 'CURRENT',
    WatchStatus.completed => 'COMPLETED',
    WatchStatus.paused => 'PAUSED',
    WatchStatus.dropped => 'DROPPED',
  };

  /// MyAnimeList `my_list_status.status` value.
  String get mal => switch (this) {
    WatchStatus.planning => 'plan_to_watch',
    WatchStatus.watching => 'watching',
    WatchStatus.completed => 'completed',
    WatchStatus.paused => 'on_hold',
    WatchStatus.dropped => 'dropped',
  };

  /// Simkl list name (`to` field on /sync/add-to-list).
  String get simkl => switch (this) {
    WatchStatus.planning => 'plantowatch',
    WatchStatus.watching => 'watching',
    WatchStatus.completed => 'completed',
    WatchStatus.paused => 'hold',
    WatchStatus.dropped => 'dropped',
  };
}

/// [WatchStatusX.label], but reading-aware: in a reading mode (manga/novel),
/// Watching reads as "Reading" and Plan to Watch as "Plan to Read" —
/// Completed/Paused/Dropped don't need a reading-specific word, so they pass
/// through unchanged. Display-only: the persisted [WatchStatusX.key] (the
/// enum `.name`) never changes, so cloud sync/backup are untouched.
String labelFor(WatchStatus s, {required bool reading}) {
  if (!reading) return s.label;
  return switch (s) {
    WatchStatus.watching => 'Reading',
    WatchStatus.planning => 'Plan to Read',
    WatchStatus.completed || WatchStatus.paused || WatchStatus.dropped => s.label,
  };
}

/// [WatchStatusX.shortLabel], but reading-aware — the compact form used by the
/// My List status tabs, where "Plan to Read" is too wide. Only `watching`
/// needs a reading word ("Reading"); `planning` already reads fine as
/// "Planning" in both modes. Display-only, exactly like [labelFor]:
/// `reading: false` is byte-identical to [WatchStatusX.shortLabel].
String shortLabelFor(WatchStatus s, {required bool reading}) {
  if (!reading) return s.shortLabel;
  return switch (s) {
    WatchStatus.watching => 'Reading',
    WatchStatus.planning ||
    WatchStatus.completed ||
    WatchStatus.paused ||
    WatchStatus.dropped => s.shortLabel,
  };
}

/// [WatchStatusX.mal], but reading-aware: MyAnimeList's manga list uses
/// `reading`/`plan_to_read` instead of `watching`/`plan_to_watch` —
/// `completed`/`on_hold`/`dropped` are shared. Mirrors [labelFor]'s pattern;
/// `reading: false` is byte-identical to [WatchStatusX.mal].
String malStatusFor(WatchStatus s, {required bool reading}) {
  if (!reading) return s.mal;
  return switch (s) {
    WatchStatus.watching => 'reading',
    WatchStatus.planning => 'plan_to_read',
    WatchStatus.completed || WatchStatus.paused || WatchStatus.dropped => s.mal,
  };
}

/// Parse a stored status name (null/unknown → null).
WatchStatus? watchStatusFromName(String? name) {
  if (name == null) return null;
  for (final s in WatchStatus.values) {
    if (s.name == name) return s;
  }
  return null;
}

/// Map an AniList `MediaListStatus` to our [WatchStatus]. REPEATING counts as
/// watching.
WatchStatus? watchStatusFromAniList(String? status) => switch (status) {
  'CURRENT' || 'REPEATING' => WatchStatus.watching,
  'PLANNING' => WatchStatus.planning,
  'COMPLETED' => WatchStatus.completed,
  'PAUSED' => WatchStatus.paused,
  'DROPPED' => WatchStatus.dropped,
  _ => null,
};
