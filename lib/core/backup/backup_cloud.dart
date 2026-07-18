import 'dart:convert';

import '../supabase/supabase_service.dart';

/// Thin transport seam over the `backups` Supabase table, injectable so
/// [BackupCloud] is unit-testable without a live Supabase project.
class BackupRemote {
  BackupRemote(this._service);

  final SupabaseService _service;

  Future<void> upsertRow(Map<String, dynamic> row) async {
    await _service.client.from('backups').upsert(row);
  }

  Future<Map<String, dynamic>?> getRow(String userKey) async {
    final res = await _service.client
        .from('backups')
        .select()
        .eq('user_key', userKey)
        .maybeSingle();
    return res;
  }
}

/// Supabase cloud transport for full-app backups.
///
/// Each signed-in account gets exactly one row in the `backups` table, keyed
/// by `user_key`. [upload] upserts it directly (no update-then-create dance —
/// that was an Appwrite-ism; Postgres has native upsert).
class BackupCloud {
  BackupCloud(SupabaseService service, {BackupRemote? remote})
      : _remote = remote ?? BackupRemote(service);

  final BackupRemote _remote;

  /// Upload (upsert) [payload] to the Supabase backups table.
  ///
  /// This is an explicit, user-initiated backup, so a failure is **not**
  /// swallowed — the caller must be able to report when it didn't save (e.g.
  /// the device is offline). Throws on failure.
  Future<void> upload(String userId, Map<String, dynamic> payload) async {
    await _remote.upsertRow({
      'user_key': userId,
      'payload': jsonEncode(payload),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Download the backup payload from Supabase.
  ///
  /// Returns the decoded [Map] stored in the `payload` column, or `null` if
  /// there is no row for [userId].
  Future<Map<String, dynamic>?> download(String userId) async {
    final row = await _remote.getRow(userId);
    if (row == null) return null;
    return jsonDecode(row['payload'] as String) as Map<String, dynamic>;
  }

  /// Returns the UTC timestamp of the last successful cloud backup, or `null`
  /// if no row exists for [userId] or `updated_at` doesn't parse.
  Future<DateTime?> lastBackupAt(String userId) async {
    final row = await _remote.getRow(userId);
    if (row == null) return null;
    return DateTime.tryParse(row['updated_at'] as String? ?? '');
  }
}
