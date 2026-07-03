// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../appwrite/appwrite_service.dart';
import '../environment.dart';
import '../models/media_item.dart';

/// My List, backed by Hive for instant local reads and synced to Appwrite when
/// the user is signed in. The local box is the read source (so the UI stays
/// synchronous + offline-friendly); writes go through to Appwrite best-effort.
class MyListStore {
  MyListStore(this._aw, this._currentUserId);

  /// Null only in tests (logged-out paths never touch it).
  final AppwriteService? _aw;

  /// Returns the signed-in user id, or null when logged out. Injected so the
  /// store doesn't depend on the auth feature directly.
  final String? Function() _currentUserId;

  /// Bumped whenever the contents change (toggle / cloud pull / clear) so
  /// listeners like MyListCubit can refresh — needed because a cloud pull
  /// lands asynchronously after login.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const String boxName = 'my_list';

  /// Shared box holding the last successful cloud-pull timestamp per store, so
  /// app-launch pulls can be throttled — the full list is already in the local
  /// cache and our own writes push to cloud immediately. Kept OUT of [boxName]
  /// so it never appears in [all]'s value iteration.
  static const String syncMetaBox = 'library_sync_meta';
  static const String _syncMetaKey = 'mylist_lastPullMs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
    if (!Hive.isBoxOpen(syncMetaBox)) {
      await Hive.openBox(syncMetaBox);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(MediaItem m) => '${m.sourceId}::${m.id}';

  /// Deterministic Appwrite document id for (user, item) so add/remove target
  /// the same doc. 32 hex chars (≤ 36, valid id chars).
  String _docId(String uid, String key) =>
      sha256.convert(utf8.encode('$uid::$key')).toString().substring(0, 32);

  bool contains(MediaItem m) => _box.containsKey(_key(m));

  List<MediaItem> all() => _box.values
      .map((raw) => MediaItem.fromJson(Map<String, dynamic>.from(raw)))
      .toList();

  /// Ensure [m] is in the list (no-op if already present). Used by the status
  /// sheet, where picking any status implies membership.
  Future<void> add(MediaItem m) async {
    if (_box.containsKey(_key(m))) return;
    await toggle(m);
  }

  /// Remove [m] from the list (no-op if absent).
  Future<void> remove(MediaItem m) async {
    if (!_box.containsKey(_key(m))) return;
    await toggle(m);
  }

  Future<void> toggle(MediaItem m) async {
    final k = _key(m);
    final adding = !_box.containsKey(k);
    if (adding) {
      await _box.put(k, m.toJson());
    } else {
      await _box.delete(k);
    }
    revision.value++;
    final uid = _currentUserId();
    if (uid == null) return; // gated by the UI, but guard anyway
    final docId = _docId(uid, k);
    try {
      if (adding) {
        await _aw!.databases.createDocument(
          databaseId: Environment.databaseId,
          collectionId: Environment.mylistCollectionId,
          documentId: docId,
          data: {
            'userId': uid,
            'itemId': m.id,
            'sourceId': m.sourceId,
            'title': m.title,
            'cover': m.cover,
            'coverHeaders':
                m.coverHeaders == null ? null : jsonEncode(m.coverHeaders),
            'url': m.url,
            'type': m.type.name,
            'addedAt': DateTime.now().millisecondsSinceEpoch,
          },
          permissions: [
            Permission.read(Role.user(uid)),
            Permission.update(Role.user(uid)),
            Permission.delete(Role.user(uid)),
          ],
        );
      } else {
        await _aw!.databases.deleteDocument(
          databaseId: Environment.databaseId,
          collectionId: Environment.mylistCollectionId,
          documentId: docId,
        );
      }
    } catch (_) {
      // Best-effort: the local box is already updated; cloud will reconcile on
      // the next pull.
    }
  }

  /// Replace the local cache with the signed-in user's cloud list. Called on
  /// login. No-op when logged out.
  Future<void> pullFromCloud() async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      final res = await _aw!.databases.listDocuments(
        databaseId: Environment.databaseId,
        collectionId: Environment.mylistCollectionId,
        queries: [Query.equal('userId', uid), Query.limit(500)],
      );
      await _box.clear();
      for (final d in res.documents) {
        final m = d.data;
        final headers = m['coverHeaders'];
        final item = MediaItem.fromJson({
          'id': m['itemId'],
          'title': m['title'],
          'cover': m['cover'],
          'coverHeaders': headers is String ? jsonDecode(headers) : null,
          'url': m['url'],
          'type': m['type'],
          'sourceId': m['sourceId'],
        });
        await _box.put('${item.sourceId}::${item.id}', item.toJson());
      }
      revision.value++;
      _markPulled();
    } catch (_) {/* keep whatever is local */}
  }

  /// Pull from cloud only when the last successful pull is older than [maxAge].
  /// Used on app launch (restoring a session) so the whole list isn't
  /// re-downloaded on every cold start — it's already in the local Hive cache,
  /// and our own writes push to cloud immediately. Login + pull-to-refresh call
  /// [pullFromCloud] directly to force a fresh sync.
  Future<void> pullFromCloudIfStale({
    Duration maxAge = const Duration(hours: 12),
  }) async {
    if (_currentUserId() == null) return;
    int? last;
    if (Hive.isBoxOpen(syncMetaBox)) {
      last = Hive.box(syncMetaBox).get(_syncMetaKey) as int?;
    }
    if (last != null) {
      final age = DateTime.now().millisecondsSinceEpoch - last;
      if (age >= 0 && age < maxAge.inMilliseconds) return; // still fresh
    }
    await pullFromCloud();
  }

  void _markPulled() {
    if (Hive.isBoxOpen(syncMetaBox)) {
      Hive.box(syncMetaBox)
          .put(_syncMetaKey, DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// Wipe the local cache (on logout).
  Future<void> clearLocal() async {
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_syncMetaKey);
    }
    revision.value++;
  }
}