import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/crypto_ops.dart';

void main() {
  test('sha256Hex matches the AllAnime key vector', () {
    expect(
      sha256Hex('Xot36i3lK3:v1'),
      'a254aa27c410f297bd04ba33a0c0df7ff4e706bf3ae27271c6703f84e750f552',
    );
  });

  test('aesCtrDecryptToString decrypts a known CTR vector', () {
    final data = base64Decode('3t9fAEwGPNSaDqg4RX6JzX8rIZ/1Vpw=');
    final out = aesCtrDecryptToString(
      keyHex: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      counterHex: 'aabbccddeeff00112233445566778899',
      data: Uint8List.fromList(data),
    );
    expect(out, 'hello-watch_app-aes-ctr');
  });
}
