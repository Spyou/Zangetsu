import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_relay.dart';

void main() {
  group('DiscordRelayBlob', () {
    test('round-trips token', () {
      final blob = DiscordRelayBlob(token: 'a' * 40);
      final decoded = DiscordRelayBlob.decode(blob.encode());
      expect(decoded.token, blob.token);
    });

    test('tryTokenFromJson returns null for tracker blobs', () {
      expect(
        DiscordRelayBlob.tryTokenFromJson('{"v":1,"trackers":{"mal":{}}}'),
        isNull,
      );
    });
  });
}
