import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/stremio/stremio_backup_cipher.dart';

void main() {
  test(
    'password encryption round-trips without exposing configured URLs',
    () async {
      final original = <String, dynamic>{
        'url': 'https://addon.test/private-token',
      };
      final encrypted = await StremioBackupCipher.encrypt(
        original,
        'test-password',
      );
      expect(jsonEncode(encrypted), isNot(contains('private-token')));
      expect(
        await StremioBackupCipher.decrypt(encrypted, 'test-password'),
        original,
      );
      await expectLater(
        StremioBackupCipher.decrypt(encrypted, 'wrong-password'),
        throwsA(isA<StremioBackupException>()),
      );
      final tampered = {
        ...encrypted,
        'ciphertext': base64Encode(List.filled(32, 0)),
      };
      await expectLater(
        StremioBackupCipher.decrypt(tampered, 'test-password'),
        throwsA(isA<StremioBackupException>()),
      );
    },
  );

  test(
    'rejects weak passwords and oversized or unsupported envelopes',
    () async {
      await expectLater(
        StremioBackupCipher.encrypt({}, 'short'),
        throwsA(isA<StremioBackupException>()),
      );
      await expectLater(
        StremioBackupCipher.decrypt({'format': 'unknown'}, 'test-password'),
        throwsA(isA<StremioBackupException>()),
      );
    },
  );
}
