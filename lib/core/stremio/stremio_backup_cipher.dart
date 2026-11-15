import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class StremioBackupException implements Exception {
  const StremioBackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract final class StremioBackupCipher {
  static const format = 'stremio-password-v1';
  static const maxBytes = 1024 * 1024;

  static Future<Map<String, dynamic>> encrypt(
    Map<String, dynamic> data,
    String password,
  ) => Isolate.run(() => _encrypt(data, password));

  static Future<Map<String, dynamic>> decrypt(
    Map<String, dynamic> data,
    String password,
  ) => Isolate.run(() => _decrypt(data, password));

  static Uint8List _random(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  static Uint8List _key(String password, Uint8List salt) {
    if (password.length < 8 || password.length > 1024) {
      throw const StremioBackupException(
        'Use a backup password with at least 8 characters.',
      );
    }
    return (PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
          ..init(Pbkdf2Parameters(salt, 310000, 32)))
        .process(Uint8List.fromList(utf8.encode(password)));
  }

  static Map<String, dynamic> _encrypt(
    Map<String, dynamic> data,
    String password,
  ) {
    final bytes = utf8.encode(jsonEncode(data));
    if (bytes.length > maxBytes) {
      throw const StremioBackupException('Addon backup is too large.');
    }
    final salt = _random(16);
    final nonce = _random(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_key(password, salt)),
          128,
          nonce,
          Uint8List.fromList(utf8.encode(format)),
        ),
      );
    return {
      'format': format,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(cipher.process(Uint8List.fromList(bytes))),
    };
  }

  static Map<String, dynamic> _decrypt(
    Map<String, dynamic> data,
    String password,
  ) {
    try {
      if (data['format'] != format || jsonEncode(data).length > maxBytes * 2) {
        throw const FormatException();
      }
      final salt = base64Decode(data['salt'] as String);
      final nonce = base64Decode(data['nonce'] as String);
      final bytes = base64Decode(data['ciphertext'] as String);
      if (salt.length != 16 ||
          nonce.length != 12 ||
          bytes.length > maxBytes + 16) {
        throw const FormatException();
      }
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(_key(password, salt)),
            128,
            nonce,
            Uint8List.fromList(utf8.encode(format)),
          ),
        );
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(cipher.process(bytes))) as Map,
      );
    } catch (_) {
      throw const StremioBackupException(
        'Incorrect password or damaged addon backup.',
      );
    }
  }
}
