import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/backup_file.dart';

void main() {
  test('backupFileName formats date + time', () {
    expect(backupFileName(DateTime(2026, 7, 2, 9, 5)),
        'zangetsu-backup-20260702-0905.json');
  });
  test('parseBackupJson returns the map / throws on non-object', () {
    expect(parseBackupJson('{"app":"zangetsu"}'), {'app': 'zangetsu'});
    expect(() => parseBackupJson('[1,2]'), throwsA(isA<FormatException>()));
    expect(() => parseBackupJson('not json'), throwsA(isA<FormatException>()));
  });
}
