import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Pure Discord OAuth helpers (PKCE S256, no client secret). The flow itself
/// lives in [DiscordRpc]: [discordAuthorizeUri] is opened in the browser,
/// the `discord-<appId>:/authorize/callback` redirect comes back through
/// app_links, and the code is exchanged at the token endpoint.
///
/// Mirrors the MAL tracker login in this repo; parameters mirror ArchiveTune:
/// scopes `identify sdk.social_layer_presence` — the last one is what lets an
/// OAuth access token drive presence over the gateway.
class DiscordAuth {
  DiscordAuth._();

  static const String authorizeEndpoint =
      'https://discord.com/oauth2/authorize';
  static const String tokenEndpoint = 'https://discord.com/api/oauth2/token';
  static const String meEndpoint = 'https://discord.com/api/v10/users/@me';
  static const String scopes = 'identify sdk.social_layer_presence';

  /// Custom-scheme redirect registered in the Discord portal (OAuth2 panel)
  /// and in the Android manifest / iOS plist.
  static String redirectUri(String applicationId) =>
      'discord-$applicationId:/authorize/callback';

  static Uri nativeAuthorizeUri(Uri browserUri) =>
      browserUri.replace(scheme: 'discord', host: 'action');

  static bool isCallback(Uri uri, String applicationId) =>
      uri.scheme == 'discord-$applicationId' &&
      !uri.hasAuthority &&
      uri.path == '/authorize/callback';

  /// S256 code challenge for [verifier] (RFC 7636: base64url(sha256), no pad).
  static String codeChallenge(String verifier) => base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');

  /// The browser URL that starts the login.
  static Uri authorizeUri({
    required String applicationId,
    required String state,
    required String challenge,
  }) {
    return Uri.parse(
      '$authorizeEndpoint?response_type=code'
      '&client_id=$applicationId'
      '&redirect_uri=${Uri.encodeComponent(redirectUri(applicationId))}'
      '&scope=${Uri.encodeComponent(scopes)}'
      '&state=$state'
      '&code_challenge=$challenge'
      '&code_challenge_method=S256',
    );
  }

  /// Avatar URL for a `/users/@me` payload (`a_`-prefixed hashes animate).
  static String? avatarUrl(String userId, String? hash) {
    if (userId.isEmpty || hash == null || hash.isEmpty) return null;
    final ext = hash.startsWith('a_') ? 'gif' : 'png';
    return 'https://cdn.discordapp.com/avatars/$userId/$hash.$ext?size=256';
  }
}
