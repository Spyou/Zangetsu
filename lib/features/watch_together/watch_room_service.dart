// ignore_for_file: deprecated_member_use
import 'package:appwrite/appwrite.dart';
import 'package:flutter/foundation.dart';

import '../../core/appwrite/appwrite_service.dart';
import '../../core/environment.dart';
import 'model/room_state.dart';
import 'sync_math.dart';

/// Pure Appwrite data layer for Watch Together rooms.
/// No UI or player knowledge; all Appwrite I/O is isolated here.
class WatchRoomService {
  WatchRoomService(this._aw);
  final AppwriteService _aw;

  Databases get _db => _aw.databases;

  // ── Channel helpers ────────────────────────────────────────────────────────

  String _docChannel(String col, String id) =>
      'databases.${Environment.databaseId}.collections.$col.documents.$id';

  String _colChannel(String col) =>
      'databases.${Environment.databaseId}.collections.$col.documents';

  // ── Room CRUD ──────────────────────────────────────────────────────────────

  /// Creates a room, retrying with a new code on 409 collisions (up to 5x).
  Future<RoomState> createRoom(RoomState initial) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final code = generateRoomCode(
          DateTime.now().millisecondsSinceEpoch + attempt * 7919);
      try {
        final doc = await _db.createDocument(
          databaseId: Environment.databaseId,
          collectionId: Environment.watchRoomsCollectionId,
          documentId: code,
          data: initial.copyWith().toMap()..['code'] = code,
        );
        return RoomState.fromMap(doc.data);
      } on AppwriteException catch (e) {
        if (e.code == 409) continue; // code taken — retry
        rethrow;
      }
    }
    throw StateError('could not allocate a room code after 5 attempts');
  }

  /// Returns the room for [code], or null if it does not exist.
  Future<RoomState?> getRoom(String code) async {
    try {
      final doc = await _db.getDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.watchRoomsCollectionId,
        documentId: code,
      );
      return RoomState.fromMap(doc.data);
    } on AppwriteException catch (e) {
      if (e.code == 404) return null;
      rethrow;
    }
  }

  /// Applies a partial [patch] to the room document (best-effort; errors swallowed
  /// because the next heartbeat will retry).
  Future<void> updateRoom(String code, Map<String, dynamic> patch) async {
    try {
      await _db.updateDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.watchRoomsCollectionId,
        documentId: code,
        data: patch,
      );
    } catch (_) {/* best-effort; next heartbeat retries */}
  }

  /// Emits a new [RoomState] whenever the Appwrite document for [code] changes.
  Stream<RoomState> watchRoom(String code) {
    final sub = _aw.realtime.subscribe(
        [_docChannel(Environment.watchRoomsCollectionId, code)]);
    return sub.stream
        .where((e) => e.payload.isNotEmpty)
        .map((e) => RoomState.fromMap(e.payload));
  }

  // ── Participants ───────────────────────────────────────────────────────────

  String _pid(String code, String userId) => '$code-$userId';

  /// Creates or updates the participant document for [p] in room [code].
  Future<void> upsertParticipant(String code, RoomParticipant p) async {
    final data = p.toMap()..['roomId'] = code;
    try {
      await _db.updateDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.roomParticipantsCollectionId,
        documentId: _pid(code, p.userId),
        data: data,
      );
    } on AppwriteException {
      try {
        await _db.createDocument(
          databaseId: Environment.databaseId,
          collectionId: Environment.roomParticipantsCollectionId,
          documentId: _pid(code, p.userId),
          data: data,
        );
      } catch (e) {
        debugPrint('upsertParticipant create failed: $e');
      }
    }
  }

  /// Removes the participant document for [userId] from room [code].
  Future<void> removeParticipant(String code, String userId) async {
    try {
      await _db.deleteDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.roomParticipantsCollectionId,
        documentId: _pid(code, userId),
      );
    } catch (_) {}
  }

  /// Returns the current participant list for room [code] (up to 50).
  Future<List<RoomParticipant>> listParticipants(String code) async {
    try {
      final res = await _db.listDocuments(
        databaseId: Environment.databaseId,
        collectionId: Environment.roomParticipantsCollectionId,
        queries: [Query.equal('roomId', code), Query.limit(50)],
      );
      return res.documents
          .map((d) => RoomParticipant.fromMap(d.data))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Emits a void tick whenever a participant document in room [code] changes.
  /// Caller should re-call [listParticipants] on each tick.
  Stream<void> watchParticipants(String code) {
    final sub = _aw.realtime
        .subscribe([_colChannel(Environment.roomParticipantsCollectionId)]);
    return sub.stream
        // Delete events arrive with an empty payload, so we can't match roomId on
        // them — forward those too (a delete from another room just triggers a
        // harmless redundant re-list, which the caller filters by roomId).
        .where((e) => e.payload.isEmpty || '${e.payload['roomId']}' == code)
        .map((_) {});
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  /// Sends a chat message [m] to room [code].
  Future<void> sendMessage(String code, RoomMessage m) async {
    try {
      await _db.createDocument(
        databaseId: Environment.databaseId,
        collectionId: Environment.roomMessagesCollectionId,
        documentId: ID.unique(),
        data: m.toMap()..['roomId'] = code,
      );
    } catch (_) {}
  }

  /// Returns the most recent [limit] messages for room [code], oldest-first.
  Future<List<RoomMessage>> recentMessages(String code,
      {int limit = 50}) async {
    try {
      final res = await _db.listDocuments(
        databaseId: Environment.databaseId,
        collectionId: Environment.roomMessagesCollectionId,
        queries: [
          Query.equal('roomId', code),
          Query.orderDesc('createdAt'),
          Query.limit(limit),
        ],
      );
      return res.documents.reversed
          .map((d) => RoomMessage.fromMap(d.data))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Emits each new [RoomMessage] broadcast to room [code] in real time.
  Stream<RoomMessage> watchMessages(String code) {
    final sub = _aw.realtime
        .subscribe([_colChannel(Environment.roomMessagesCollectionId)]);
    return sub.stream
        .where((e) =>
            '${e.payload['roomId']}' == code && e.payload['text'] != null)
        .map((e) => RoomMessage.fromMap(e.payload));
  }
}
