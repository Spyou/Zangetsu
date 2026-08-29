import 'dart:convert';

/// Encrypted relay payload for sending a Discord user token from a phone to a TV.
class DiscordRelayBlob {
  const DiscordRelayBlob({this.version = currentVersion, required this.token});

  static const int currentVersion = 1;

  final int version;
  final String token;

  String encode() => jsonEncode({'v': version, 'discord': {'token': token}});

  factory DiscordRelayBlob.decode(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    final d = j['discord'] as Map?;
    final token = d?['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const FormatException('missing discord token');
    }
    return DiscordRelayBlob(
      version: (j['v'] as num?)?.toInt() ?? 1,
      token: token,
    );
  }

  /// Returns the token when [json] is a discord relay blob, else null.
  static String? tryTokenFromJson(String json) {
    try {
      return DiscordRelayBlob.decode(json).token;
    } catch (_) {
      return null;
    }
  }
}
