import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'profile_lock_remote.dart';

/// Device-only verification of a PIN previously accepted by the sync server.
class OfflineProfilePin {
  OfflineProfilePin(this._storage);

  final FlutterSecureStorage _storage;
  final _pending = <String, Future<void>>{};
  static const _iterations = 100000;

  Future<void> save(String key, String pin, int version) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List.generate(16, (_) => random.nextInt(256)),
    );
    final hash = await _derive(pin, salt);
    await _write(key, {
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
      'version': version,
      'attempts': 0,
    });
  }

  Future<bool> hasVersion(String key, int version) async {
    try {
      return (await _read(key))?['version'] == version;
    } on FormatException {
      return false;
    }
  }

  Future<bool> verify(String key, String pin, int version) {
    final result = (_pending[key] ?? Future<void>.value()).then(
      (_) => _verify(key, pin, version),
    );
    final completed = result.then<void>((_) {}, onError: (Object _) {});
    _pending[key] = completed;
    completed.then((_) {
      if (identical(_pending[key], completed)) _pending.remove(key);
    });
    return result;
  }

  Future<bool> _verify(String key, String pin, int version) async {
    final value = await _read(key);
    if (value == null || value['version'] != version) {
      throw const ProfileLockException('offline_pin_unavailable');
    }
    final retryAt = value['retry_at'] as int? ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (retryAt > now) {
      throw ProfileLockException(
        'rate_limited',
        retryAfter: ((retryAt - now) / 1000).ceil(),
      );
    }
    final expected = base64Decode(value['hash'] as String);
    final actual = await _derive(pin, base64Decode(value['salt'] as String));
    var different = actual.length ^ expected.length;
    for (var i = 0; i < min(actual.length, expected.length); i++) {
      different |= actual[i] ^ expected[i];
    }
    final valid = different == 0;
    final attempts = valid ? 0 : (value['attempts'] as int) + 1;
    await _write(key, {
      ...value,
      'attempts': attempts,
      'retry_at': attempts >= 5 ? now + 300000 : 0,
    });
    return valid;
  }

  Future<void> delete(String key) => _storage.delete(key: key);

  Future<Map<String, dynamic>?> _read(String key) async {
    final raw = await _storage.read(key: key);
    if (raw == null) return null;
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['version'] is! int ||
        value['salt'] is! String ||
        value['hash'] is! String ||
        value['attempts'] is! int ||
        (value['attempts'] as int) < 0 ||
        (value['retry_at'] != null && value['retry_at'] is! int) ||
        base64Decode(value['salt'] as String).length != 16 ||
        base64Decode(value['hash'] as String).length != 32) {
      throw const FormatException('Invalid offline profile lock');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<void> _write(String key, Map<String, dynamic> value) => _storage.write(
    key: key,
    value: jsonEncode(value),
    iOptions: const IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: const MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static Future<Uint8List> _derive(String pin, Uint8List salt) =>
      Isolate.run(() {
        final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
          ..init(Pbkdf2Parameters(salt, _iterations, 32));
        return derivator.process(Uint8List.fromList(utf8.encode(pin)));
      });
}
