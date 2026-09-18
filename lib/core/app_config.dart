/// Single source of truth for the product name. Final rename = one
/// find/replace on the token `WATCH_APP` across the repo, plus a bundle-id
/// rename (`flutter pub run rename` or manual android/ios edits).
const String kAppName = 'Zangetsu';

/// Running app version shown in Settings/About. Populated from the real build
/// (PackageInfo) at boot so it never goes stale; this literal is just the
/// pre-boot fallback.
String kAppVersion = '1.0.0';

/// Build number behind [kAppVersion], e.g. `13108`. Kept separate because
/// [kAppVersion] is user-facing (Settings shows `v2.0.0`) and goes out as the
/// Simkl `app-version` header, and neither wants a build number. A log report
/// does: "2.0.0" spans every build of a release, and knowing which one a
/// report came from is the whole point.
String kAppBuild = '';

/// Stable application id embedded in default provider-repo manifests and
/// checked by the repo guard so a manga-only (Sozo) repo can't be added.
const String kAppId = 'watch_app';

/// Manifest schema version this app speaks. Repos below this are rejected.
const int kManifestSchemaVersion = 2;

/// Community Discord invite. Lived in two places (the launch community sheet
/// and Settings → About) and drifted — the sheet's copy went stale and expired.
/// One const now, so refreshing the invite is a single edit here.
const String kDiscordInviteUrl = 'https://discord.gg/hey6vz9kg6';

/// Where "Send report" posts the diagnostic log — the Cloudflare Worker in
/// `cloudflare/log-intake/` (see its README to deploy). No path, no trailing
/// slash.
///
/// Empty means "not set up" — the report button falls back to the share sheet
/// rather than failing, so a fork with no Worker of its own still works.
///
/// Only the public URL lives here. The Discord webhook stays on the Worker:
/// this app is open source and its APK is public, so anything put in the app
/// can be read straight back out of it.
const String kLogIntakeUrl = 'https://zangetsu-logs.log-intake.workers.dev';

/// Developer announcements feed (a plain JSON file in the public app repo).
/// The app READS this on launch to show in-app announcements — never writes.
/// Edit + push that file to broadcast a message to every user.
const String kAnnouncementsUrl =
    'https://raw.githubusercontent.com/Spyou/Zangetsu/main/announcements.json';

/// TMDB API key for movie/TV trailer lookups (TrailerService). Anime trailers
/// use AniList and need no key. Supply via `--dart-define=TMDB_API_KEY=...`,
/// or paste a literal default below. When empty, movie/TV trailers are
/// gracefully disabled (the Trailer button simply never appears for them).
const String kTmdbApiKey = String.fromEnvironment(
  'TMDB_API_KEY',
  defaultValue: '',
);
