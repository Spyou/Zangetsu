import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Lowercase hex SHA-256 of [message] (UTF-8).
String sha256Hex(String message) =>
    crypto.sha256.convert(utf8.encode(message)).toString();

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// AES-256-CTR decrypt [data] with [keyHex] (32 bytes) and the 16-byte initial
/// counter [counterHex]; returns the plaintext decoded as UTF-8. Matches
/// OpenSSL/Node `aes-256-ctr` (full 128-bit big-endian counter increment).
String aesCtrDecryptToString({
  required String keyHex,
  required String counterHex,
  required Uint8List data,
}) {
  final cipher = CTRStreamCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV(
        KeyParameter(_hexToBytes(keyHex)),
        _hexToBytes(counterHex),
      ),
    );
  final out = cipher.process(data);
  return utf8.decode(out, allowMalformed: true);
}
