import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/backup_cloud.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';

/// In-memory fake for [BackupRemote] so [BackupCloud] can be tested without a
/// live Supabase project.
class FakeBackupRemote implements BackupRemote {
  final Map<String, Map<String, dynamic>> byUser = {};

  @override
  Future<void> upsertRow(Map<String, dynamic> row) async {
    byUser[row['user_key'] as String] = row;
  }

  @override
  Future<Map<String, dynamic>?> getRow(String userKey) async {
    return byUser[userKey];
  }
}

void main() {
  late FakeBackupRemote fake;
  late BackupCloud backup;

  setUp(() {
    fake = FakeBackupRemote();
    backup = BackupCloud(SupabaseService(), remote: fake);
  });

  test('upload then download round-trips the payload map', () async {
    final payload = {'mylist': [1, 2, 3], 'settings': {'theme': 'dark'}};

    await backup.upload('user1', payload);
    final result = await backup.download('user1');

    expect(result, payload);
  });

  test('lastBackupAt parses the stored updated_at to a DateTime', () async {
    await backup.upload('user1', {'a': 1});

    final ts = await backup.lastBackupAt('user1');

    expect(ts, isA<DateTime>());
    expect(ts!.difference(DateTime.now().toUtc()).abs() < const Duration(minutes: 1), isTrue);
  });

  test('download for a user with no row returns null', () async {
    final result = await backup.download('nobody');
    expect(result, isNull);
  });
}
