import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for the Discord user token. The token grants full account
/// access, so it lives ONLY in the platform keystore — never Hive, never logs.
class DiscordTokenStore {
  DiscordTokenStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const String _key = 'discord_user_token';

  static Future<String?> read() => _storage.read(key: _key);
  static Future<void> write(String token) =>
      _storage.write(key: _key, value: token);
  static Future<void> clear() => _storage.delete(key: _key);
}
