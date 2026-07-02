import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/backup_payload.dart';

void main() {
  test('wrap then unwrap round-trips the selected bundles', () {
    final wrapped = wrapPayload(
      {BackupBundle.settings: {'k': 1}},
      createdAtIso: '2026-07-02T00:00:00Z',
    );
    expect(wrapped['app'], 'zangetsu');
    expect(wrapped['version'], 1);
    final out = unwrapPayload(wrapped);
    expect(out[BackupBundle.settings], {'k': 1});
    expect(out.containsKey(BackupBundle.library), isFalse);
  });

  test('unwrap rejects a foreign or newer payload', () {
    expect(() => unwrapPayload({'app': 'other', 'version': 1, 'bundles': {}}),
        throwsA(isA<BackupFormatException>()));
    expect(() => unwrapPayload({'app': 'zangetsu', 'version': 2, 'bundles': {}}),
        throwsA(isA<BackupFormatException>()));
  });
}
