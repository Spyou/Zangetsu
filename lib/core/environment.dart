/// Public Appwrite configuration. These are NOT secrets — the project id and
/// endpoint ship in every Appwrite client app. Auth uses email/password
/// sessions; the server API key is never embedded here.
class Environment {
  static const String appwriteProjectId = '6a1ed44f0029b50bccde';
  static const String appwriteProjectName = 'Zangetsu';
  static const String appwritePublicEndpoint = 'https://sgp.cloud.appwrite.io/v1';

  // Provisioned backend ids (see docs / setup).
  static const String databaseId = 'main';
  static const String mylistCollectionId = 'mylist';
  static const String historyCollectionId = 'history';
  static const String watchRoomsCollectionId = 'watch_rooms';
  static const String roomParticipantsCollectionId = 'room_participants';
  static const String roomMessagesCollectionId = 'room_messages';
  static const String avatarsBucketId = 'avatars';

  // ── Tracker OAuth ──────────────────────────────────────────────────────────
  // All redirects share the zangetsu:// scheme; each has its own host with a
  // matching Android intent-filter. Client secrets are embedded where the
  // provider's token exchange requires it (MAL = PKCE, no secret; Simkl needs
  // one) — standard for these APIs and low-risk.
  static const String trackerRedirectScheme = 'zangetsu';

  // AniList — implicit grant (token in URL fragment, 1-year, no secret).
  static const String anilistClientId = '43052';
  static const String anilistRedirectHost = 'anilist-auth';
  static String get anilistRedirectUri =>
      '$trackerRedirectScheme://$anilistRedirectHost';

  // MyAnimeList — OAuth2 PKCE (plain), no client secret.
  static const String malClientId = 'ac006943589381143c4c4e54eac93a89';
  static const String malRedirectHost = 'mal-auth';
  static String get malRedirectUri =>
      '$trackerRedirectScheme://$malRedirectHost';

  // Simkl — OAuth2 authorization-code (needs the secret to exchange the code).
  static const String simklClientId =
      '8b847b09206ccdb0b3de4cc1293d6dd7d355821f5c179c57315da8ba9030eb53';
  static const String simklClientSecret =
      '34ba8e5ac7c8a5c27926dfdf78205e5b913de9928361cb5a243558239298c96d';
  static const String simklRedirectHost = 'simkl-auth';
  static String get simklRedirectUri =>
      '$trackerRedirectScheme://$simklRedirectHost';

  // Back-compat alias (older AniList code referenced this name).
  static const String anilistRedirectScheme = trackerRedirectScheme;
}
