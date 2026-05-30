/// Single source of truth for the product name. Final rename = one
/// find/replace on the token `WATCH_APP` across the repo, plus a bundle-id
/// rename (`flutter pub run rename` or manual android/ios edits).
const String kAppName = 'WATCH_APP';

/// Stable application id embedded in default provider-repo manifests and
/// checked by the repo guard so a manga-only (Sozo) repo can't be added.
const String kAppId = 'watch_app';

/// Manifest schema version this app speaks. Repos below this are rejected.
const int kManifestSchemaVersion = 2;
