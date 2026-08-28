import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'debrid_provider.dart';

/// Secure storage for debrid API tokens. Same rule as Discord: the token
/// lives ONLY in the platform keystore — never Hive, never logs, never backup.
class DebridTokenStore {
  DebridTokenStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String _key(DebridService s) => switch (s) {
        DebridService.realDebrid => 'debrid_real_debrid_token',
        DebridService.torbox => 'debrid_torbox_token',
      };

  static Future<String?> read(DebridService s) => _storage.read(key: _key(s));

  static Future<void> write(DebridService s, String token) =>
      _storage.write(key: _key(s), value: token);

  static Future<void> clear(DebridService s) => _storage.delete(key: _key(s));

  static Future<bool> hasToken(DebridService s) async {
    final t = await read(s);
    return t != null && t.trim().isNotEmpty;
  }
}
