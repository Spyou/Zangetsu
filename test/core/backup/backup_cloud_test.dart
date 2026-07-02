import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/backup/backup_cloud.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────────

/// Fake Databases that stubs only the three calls BackupCloud makes.
/// All other Databases methods are forwarded to noSuchMethod.
class _FakeDatabases implements Databases {
  _FakeDatabases({this.updateShouldThrow = false});

  final bool updateShouldThrow;
  bool createCalled = false;

  models.Document _stubDoc() => models.Document.fromMap({
        '\$id': 'testdocid',
        '\$collectionId': 'backups',
        '\$databaseId': 'main',
        '\$createdAt': '2026-07-02T00:00:00.000Z',
        '\$updatedAt': '2026-07-02T00:00:00.000Z',
        '\$permissions': <String>[],
        'payload': jsonEncode({'app': 'zangetsu'}),
        'updatedAt': '2026-07-02T00:00:00Z',
        'userId': 'u1',
      });

  @override
  Future<models.Document> getDocument({
    required String databaseId,
    required String collectionId,
    required String documentId,
    List<String>? queries,
    String? transactionId,
  }) async =>
      _stubDoc();

  @override
  Future<models.Document> updateDocument({
    required String databaseId,
    required String collectionId,
    required String documentId,
    Map? data,
    List<String>? permissions,
    String? transactionId,
  }) async {
    if (updateShouldThrow) throw AppwriteException('document not found', 404);
    return _stubDoc();
  }

  @override
  Future<models.Document> createDocument({
    required String databaseId,
    required String collectionId,
    required String documentId,
    required Map data,
    List<String>? permissions,
    String? transactionId,
  }) async {
    createCalled = true;
    return _stubDoc();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Fake AppwriteService that exposes a fake Databases instance.
class _FakeAppwriteService implements AppwriteService {
  _FakeAppwriteService(this._db);
  final _FakeDatabases _db;

  @override
  Databases get databases => _db;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  // ── docId ───────────────────────────────────────────────────────────────────

  group('BackupCloud.docId', () {
    test('is 32 lowercase hex characters', () {
      final id = BackupCloud.docId('u1');
      expect(id.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id), isTrue);
    });

    test('is stable — same input yields same output', () {
      expect(BackupCloud.docId('u1'), equals(BackupCloud.docId('u1')));
    });

    test('differs for different userIds', () {
      expect(
        BackupCloud.docId('u1'),
        isNot(equals(BackupCloud.docId('u2'))),
      );
    });
  });

  // ── download ────────────────────────────────────────────────────────────────

  group('BackupCloud.download', () {
    test('returns decoded payload map on success', () async {
      final db = _FakeDatabases();
      final cloud = BackupCloud(_FakeAppwriteService(db));

      final result = await cloud.download('u1');

      expect(result, isNotNull);
      expect(result!['app'], 'zangetsu');
    });
  });

  // ── lastBackupAt ────────────────────────────────────────────────────────────

  group('BackupCloud.lastBackupAt', () {
    test('returns parsed UTC DateTime on success', () async {
      final db = _FakeDatabases();
      final cloud = BackupCloud(_FakeAppwriteService(db));

      final result = await cloud.lastBackupAt('u1');

      expect(result, isNotNull);
      expect(result, equals(DateTime.parse('2026-07-02T00:00:00Z')));
    });
  });

  // ── upload ──────────────────────────────────────────────────────────────────

  group('BackupCloud.upload', () {
    test('calls updateDocument and skips createDocument when update succeeds',
        () async {
      final db = _FakeDatabases(updateShouldThrow: false);
      final cloud = BackupCloud(_FakeAppwriteService(db));

      await cloud.upload('u1', {'app': 'zangetsu'});

      expect(db.createCalled, isFalse);
    });

    test('falls back to createDocument when updateDocument throws', () async {
      final db = _FakeDatabases(updateShouldThrow: true);
      final cloud = BackupCloud(_FakeAppwriteService(db));

      await cloud.upload('u1', {'app': 'zangetsu'});

      expect(db.createCalled, isTrue);
    });
  });
}
