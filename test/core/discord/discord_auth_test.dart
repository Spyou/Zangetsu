import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_auth.dart';

void main() {
  group('DiscordAuth', () {
    test('S256 challenge is base64url(sha256) with padding stripped', () {
      // Cross-checked with openssl/python; the RFC appendix string is
      // frequently mistyped, so this pins the implementation, not memory.
      expect(
        DiscordAuth.codeChallenge(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        ),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('authorize URL carries the client, redirect, scopes and PKCE', () {
      final uri = DiscordAuth.authorizeUri(
        applicationId: '123',
        state: 's',
        challenge: 'c',
      );
      expect(uri.host, 'discord.com');
      expect(uri.queryParameters['client_id'], '123');
      expect(uri.queryParameters['response_type'], 'code');
      expect(
        uri.queryParameters['redirect_uri'],
        'discord-123:/authorize/callback',
      );
      expect(
        uri.queryParameters['scope'],
        'identify sdk.social_layer_presence',
      );
      expect(uri.queryParameters['code_challenge_method'], 'S256');
    });

    test('native authorization keeps the browser OAuth parameters', () {
      final web = DiscordAuth.authorizeUri(
        applicationId: '123',
        state: 's',
        challenge: 'c',
      );
      final native = DiscordAuth.nativeAuthorizeUri(web);
      expect(native.scheme, 'discord');
      expect(native.host, 'action');
      expect(native.path, '/oauth2/authorize');
      expect(native.queryParameters, web.queryParameters);
    });

    test('only the exact callback target is accepted', () {
      expect(
        DiscordAuth.isCallback(
          Uri.parse('discord-123:/authorize/callback?code=x'),
          '123',
        ),
        isTrue,
      );
      expect(
        DiscordAuth.isCallback(Uri.parse('discord-123:/other?code=x'), '123'),
        isFalse,
      );
      expect(
        DiscordAuth.isCallback(
          Uri.parse('discord-123://other/authorize/callback'),
          '123',
        ),
        isFalse,
      );
      expect(
        DiscordAuth.isCallback(
          Uri.parse('discord-456:/authorize/callback'),
          '123',
        ),
        isFalse,
      );
    });

    test('avatar URL animates for a_ hashes, png otherwise', () {
      expect(
        DiscordAuth.avatarUrl('1', 'a_abc'),
        'https://cdn.discordapp.com/avatars/1/a_abc.gif?size=256',
      );
      expect(
        DiscordAuth.avatarUrl('1', 'abc'),
        'https://cdn.discordapp.com/avatars/1/abc.png?size=256',
      );
      expect(DiscordAuth.avatarUrl('', 'abc'), isNull);
      expect(DiscordAuth.avatarUrl('1', null), isNull);
    });
  });
}
