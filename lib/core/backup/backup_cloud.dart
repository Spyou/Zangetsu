// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:crypto/crypto.dart';

import '../appwrite/appwrite_service.dart';
import '../environment.dart';

/// Appwrite cloud transport for full-app backups.
///
/// Each signed-in account gets exactly one document in the [backups] collection,
/// identified by a deterministic sha256-based id. The [upload] method uses the
/// same update-then-create upsert pattern as WatchHistory._pushToCloud.
class BackupCloud {
  BackupCloud(this._aw);
  final AppwriteService _aw;

  /// Deterministic per-account document id: sha256("$userId::backup")[:32].
  static String docId(String userId) =>
      sha256.convert(utf8.encode('$userId::backup')).toString().substring(0, 32);

  /// Upload (upsert) [payload] to the Appwrite backups collection.
  ///
  /// Tries to update the existing document first; if that fails (first write /
  /// 404) it creates a new one with owner-only permissions. A create failure is
  /// **not** swallowed — this is an explicit, user-initiated backup, so the
  /// caller must be able to report when it didn't save (e.g. the backups
  /// collection isn't set up yet, or the device is offline). Throws on failure.
  Future<void> upload(String userId, Map<String, dynamic> payload) async {
    final id = docId(userId);
    final data = {
      'userId': userId,
      'payload': jsonEncode(payload),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      await _aw.databases.updateDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.backupsCollectionId,
        documentId: id,
        data: data,
      );
    } catch (_) {
      // No document yet (first backup) or the update failed → create it. Let a
      // create failure propagate so the UI reports the backup didn't save.
      await _aw.databases.createDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.backupsCollectionId,
        documentId: id,
        data: data,
        permissions: [
          Permission.read(Role.user(userId)),
          Permission.update(Role.user(userId)),
          Permission.delete(Role.user(userId)),
        ],
      );
    }
  }

  /// Download the backup payload from Appwrite.
  ///
  /// Returns the decoded [Map] stored in the `payload` field, or `null` on
  /// 404, network failure, or any other error.
  Future<Map<String, dynamic>?> download(String userId) async {
    try {
      final doc = await _aw.databases.getDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.backupsCollectionId,
        documentId: docId(userId),
      );
      final raw = doc.data['payload'];
      if (raw is! String) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Returns the UTC timestamp of the last successful cloud backup, or `null`
  /// if the document does not exist or any error occurs.
  Future<DateTime?> lastBackupAt(String userId) async {
    try {
      final doc = await _aw.databases.getDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.backupsCollectionId,
        documentId: docId(userId),
      );
      return DateTime.tryParse(doc.data['updatedAt'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }
}
