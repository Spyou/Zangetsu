import 'package:flutter/foundation.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/hive/hive_key.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/provider_info.dart';
import '../privacy/incognito_mode.dart';
import '../profiles/profile_scope.dart';
import '../supabase/supabase_service.dart';
import '../zmode/zmode_ids.dart';

/// Parse a persisted [ReadEntry.type] name. Only 'manga'/'novel' are
/// meaningful here; anything else — including a row saved before this field
/// existed — falls back to [ProviderType.novel]. That's a deliberate,
/// backward-compatible default: every entry ever written before this field
/// existed was ALWAYS opened via NovelReaderScreen (that was true even after
/// MangaReaderScreen shipped — [ReadEntry] had no discriminator for
/// `_resumeReading` to route on), so defaulting a fieldless legacy row to
/// `novel` reproduces exactly the routing it already got. A legacy manga row
/// keeps today's (pre-existing) mis-routing instead of gaining a NEW failure
/// mode; only entries saved from this point on carry a real type and route
/// correctly.
ProviderType readEntryTypeFromName(String? name) =>
    name == ProviderType.manga.name ? ProviderType.manga : ProviderType.novel;

/// Show URL written onto new history rows. Prefers the metadata (zm://) URL
/// so a Continue Reading card reopens the metadata detail — streaming cards
/// already carry theirs, which is why those always land on metadata. Falls
/// back to the given url for pure-source titles, which keep today's
/// behaviour exactly.
String preferredHistoryUrl(
  ProviderType type, {
  int? malId,
  String? showId,
  String? showUrl,
}) {
  if (showUrl != null && ZmodeIds.isZ(showUrl)) return showUrl;
  final kind = switch (type) {
    ProviderType.manga => ZKind.manga,
    ProviderType.novel => ZKind.novel,
    _ => null,
  };
  if (kind != null) {
    if (malId != null) return ZmodeIds.showUrl(ZCanonical(kind, 'mal:$malId'));
    if (showId != null && RegExp(r'^(?:al|mal):\d+$').hasMatch(showId)) {
      return ZmodeIds.showUrl(ZCanonical(kind, showId));
    }
  }
  return showUrl ?? showId ?? '';
}

class ReadEntry {
  ReadEntry({
    required this.sourceId,
    required this.showId,
    this.showUrl,
    required this.title,
    this.cover,
    required this.chapterId,
    this.chapterNumber,
    required this.chapterUrl,
    required this.pos,
    required this.total,
    required this.updatedMs,
    required this.type,
  });

  final String sourceId, showId, title, chapterId, chapterUrl;
  final String? showUrl;
  final String? cover;
  final double? chapterNumber;
  final int pos, total, updatedMs;

  /// manga or novel — which reader [showId]'s chapters open in. See
  /// [readEntryTypeFromName] for the missing/legacy-row default.
  final ProviderType type;

  /// URL used to reopen the title's detail page. Metadata-backed titles have
  /// a stable ID such as `mal:42`/`al:42` but must be routed by their `zm://`
  /// URL. Older rows did not store that URL, so recover it from those canonical
  /// IDs; ordinary source rows keep their previous showId fallback.
  String get detailUrl {
    if (showUrl != null && showUrl!.isNotEmpty) return showUrl!;
    final kind = switch (type) {
      ProviderType.manga => ZKind.manga,
      ProviderType.novel => ZKind.novel,
      _ => null,
    };
    if (kind != null && RegExp(r'^(?:al|mal):\d+$').hasMatch(showId)) {
      return ZmodeIds.showUrl(ZCanonical(kind, showId));
    }
    return showId;
  }

  /// Same finished rule as [ReadStore]: total == 1000 is the novel
  /// scroll-permille convention (>=950 counts as done); otherwise last
  /// page/chapter (manga).
  bool get finished =>
      total > 0 && (total == 1000 ? pos >= 950 : pos >= total - 1);

  /// Reconstructs the internal native-image marker (`x-mihon-src` / `x-ani-src`)
  /// from the stored [sourceId], so Continue-Reading covers on a Cloudflare-gated
  /// image host route through the native, cf_clearance-carrying image path — the
  /// same way fresh browse covers do (see `mihon_mapping`/`aniyomi_mapping`). The
  /// marker is a UI-only key, never sent over the network. Null for JS/other
  /// sources, which fall back to CachedNetworkImage as before.
  Map<String, String>? get coverHeaders {
    if (sourceId.startsWith('mihon:')) {
      return {'x-mihon-src': sourceId.substring(6)};
    }
    if (sourceId.startsWith('ani:')) {
      return {'x-ani-src': sourceId.substring(4)};
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'showId': showId,
    'showUrl': detailUrl,
    'title': title,
    'cover': cover,
    'chapterId': chapterId,
    'chapterNumber': chapterNumber,
    'chapterUrl': chapterUrl,
    'pos': pos,
    'total': total,
    'updatedMs': updatedMs,
    'type': type.name,
  };

  factory ReadEntry.fromJson(Map<String, dynamic> m) => ReadEntry(
    sourceId: m['sourceId'] as String,
    showId: m['showId'] as String,
    showUrl: m['showUrl'] as String?,
    title: m['title'] as String? ?? '',
    cover: m['cover'] as String?,
    chapterId: m['chapterId'] as String? ?? '',
    chapterNumber: (m['chapterNumber'] as num?)?.toDouble(),
    chapterUrl: m['chapterUrl'] as String? ?? '',
    pos: (m['pos'] as num?)?.toInt() ?? 0,
    total: (m['total'] as num?)?.toInt() ?? 0,
    updatedMs: (m['updatedMs'] as num?)?.toInt() ?? 0,
    type: readEntryTypeFromName(m['type'] as String?),
  );
}

/// Thin transport seam over the `reading_history` Supabase table, injectable
/// so [ReadHistory]'s throttle/flush logic is unit-testable without a live
/// Supabase project. Mirrors [HistoryRemote] in watch_history.dart.
class ReadingHistoryRemote {
  ReadingHistoryRemote(this._service);

  final SupabaseService _service;
  static const int pageSize = 200;
  static const int _seedPageSize = 1000;
  static const String _readingColumns =
      'source_id,show_id,title,cover,chapter_id,chapter_number,chapter_url,pos,total,updated_ms,type';

  Future<void> upsert(Map<String, dynamic> row) async {
    final profileId = row['profile_id'] as String?;
    final table = profileId == null
        ? 'reading_history'
        : 'profile_reading_history';
    final conflict = profileId == null
        ? 'user_key,source_id,show_id'
        : 'user_key,profile_id,source_id,show_id';
    await _service.client.from(table).upsert(row, onConflict: conflict);
  }

  Future<List<Map<String, dynamic>>> listFor(
    String userKey, {
    String? profileId,
  }) async {
    final table = profileId == null
        ? 'reading_history'
        : 'profile_reading_history';
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      var query = _service.client
          .from(table)
          .select('source_id,show_id,updated_ms')
          .eq('user_key', userKey);
      if (profileId != null) query = query.eq('profile_id', profileId);
      final page =
          (await query
                      .order('source_id')
                      .order('show_id')
                      .range(offset, offset + _seedPageSize - 1)
                  as List)
              .cast<Map<String, dynamic>>();
      if (page.isEmpty) break;
      rows.addAll(page);
      offset += page.length;
      if (page.length < _seedPageSize) break;
    }
    return rows;
  }

  /// shortcut: offset pages may drift during concurrent cloud edits; switch to
  /// keyset cursors if users observe skipped rows while scrolling.
  Future<List<Map<String, dynamic>>> pageFor(
    String userKey, {
    String? profileId,
    required ProviderType type,
    required int offset,
  }) async {
    final table = profileId == null
        ? 'reading_history'
        : 'profile_reading_history';
    var query = _service.client
        .from(table)
        .select(_readingColumns)
        .eq('user_key', userKey);
    if (profileId != null) query = query.eq('profile_id', profileId);
    query = type == ProviderType.manga
        ? query.eq('type', type.name)
        : query.or('type.neq.manga,type.is.null');
    final page =
        (await query
                    .order('updated_ms', ascending: false)
                    .order('source_id')
                    .order('show_id')
                    .range(offset, offset + pageSize - 1)
                as List)
            .cast<Map<String, dynamic>>();
    return page;
  }

  Future<Map<String, dynamic>?> getFor(
    String userKey, {
    String? profileId,
    required String sourceId,
    required String showId,
  }) async {
    final table = profileId == null
        ? 'reading_history'
        : 'profile_reading_history';
    var query = _service.client
        .from(table)
        .select(_readingColumns)
        .eq('user_key', userKey)
        .eq('source_id', sourceId)
        .eq('show_id', showId);
    if (profileId != null) query = query.eq('profile_id', profileId);
    final row = await query.maybeSingle();
    return (row as Map?)?.cast<String, dynamic>();
  }

  Future<void> deleteRow(
    String userKey,
    String sourceId,
    String showId, {
    String? profileId,
  }) async {
    final table = profileId == null
        ? 'reading_history'
        : 'profile_reading_history';
    await _service.client.from(table).delete().match({
      'user_key': userKey,
      'source_id': sourceId,
      'show_id': showId,
      'profile_id': ?profileId,
    });
  }

  /// Delete every reading-history row for [userKey] of one kind
  /// (`'manga'`/`'novel'`) — used by the per-tab "Clear history" so it can't
  /// sync back, and so clearing manga never touches novel (they share a table).
  Future<void> deleteAllForType(
    String userKey,
    String typeName, {
    String? profileId,
  }) async {
    final table = profileId == null
        ? 'reading_history'
        : 'profile_reading_history';
    var query = _service.client
        .from(table)
        .delete()
        .eq('user_key', userKey)
        .eq('type', typeName);
    if (profileId != null) query = query.eq('profile_id', profileId);
    await query;
  }
}

/// Continue Reading, backed by Hive for instant local reads and synced to
/// Supabase when signed in. The manga/novel sibling of [WatchHistory] — same
/// box/table/throttle/merge shape, ReadEntry fields instead of HistoryEntry.
class ReadHistory {
  ReadHistory(
    SupabaseService service,
    this._currentUserId, {
    ReadingHistoryRemote? remote,
    String? Function()? currentProfileId,
  }) : _remote = remote ?? ReadingHistoryRemote(service),
       _currentProfileId = currentProfileId;

  final ReadingHistoryRemote _remote;
  final String? Function() _currentUserId;
  final String? Function()? _currentProfileId;
  String get _profileId => _currentProfileId?.call() ?? kDefaultProfileId;
  String? _remoteProfileId(String id) => id == kDefaultProfileId ? null : id;

  static const String boxName = 'read_history';
  // Same rationale as WatchHistory's throttle: local saves stay instant, the
  // cloud push is throttled to 2 min and forced on flush (chapter change /
  // reader close) so cross-device resume stays accurate without hammering
  // free-tier write quotas.
  static const int _cloudThrottleMs = 120000;

  static const String syncMetaBox = 'library_sync_meta';
  static const String _syncMetaKey = 'reading_history_lastPullMs';
  static const String _seedFlagPrefix = 'reading_history_seeded_';
  static const String _cloudPagePrefix = 'reading_history_page:';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
    if (!Hive.isBoxOpen(syncMetaBox)) {
      await openBoxSafely(syncMetaBox);
    }
    // Same reasoning as [MyListStore.init]: an unreadable box reopens empty
    // while the pull throttle in [syncMetaBox] survives, which would skip the
    // very pull that puts the reading history back. Drop it.
    if (quarantinedBoxes.contains(boxName) && Hive.isBoxOpen(syncMetaBox)) {
      final meta = Hive.box(syncMetaBox);
      await meta.delete(_syncMetaKey);
      for (final key in meta.keys.toList()) {
        if ('$key'.contains(_cloudPagePrefix)) await meta.delete(key);
      }
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  String _key(String sourceId, String showId, [String? profileId]) =>
      profileScopedKey(profileId ?? _profileId, hiveKey('$sourceId::$showId'));
  final Map<String, int> _lastCloudPush = {};

  String _cloudPageKey(String userId, String profileId, ProviderType type) =>
      profileScopedKey(
        profileId,
        '$_cloudPagePrefix${hiveKey(userId)}:${type.name}',
      );

  Map _cloudPageState(String userId, String profileId, ProviderType type) {
    if (!Hive.isBoxOpen(syncMetaBox)) return const {};
    final state = Hive.box(
      syncMetaBox,
    ).get(_cloudPageKey(userId, profileId, type));
    return state is Map ? state : const {};
  }

  bool hasMoreCloudPages(ProviderType type, {String? forProfileId}) {
    final uid = _currentUserId();
    if (uid == null) return false;
    final profileId = forProfileId ?? _profileId;
    return _cloudPageState(uid, profileId, type)['hasMore'] as bool? ?? true;
  }

  Future<void> _saveCloudPageState(
    String userId,
    String profileId,
    ProviderType type, {
    required int offset,
    required bool hasMore,
  }) async {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    await Hive.box(syncMetaBox).put(_cloudPageKey(userId, profileId, type), {
      'offset': offset,
      'hasMore': hasMore,
    });
  }

  /// Persist progress. The local write is ALWAYS immediate (instant resume);
  /// the cloud push is throttled unless [flush] is true.
  Future<void> save(ReadEntry e, {bool flush = false}) async {
    if (IncognitoMode.on) return; // incognito: don't record what's read
    final profileId = _profileId;
    final key = _key(e.sourceId, e.showId, profileId);
    await _box.put(key, e.toJson());
    if (flush) {
      await _pushToCloud(key, e, profileId, force: true);
    } else {
      _pushToCloud(key, e, profileId);
    }
  }

  Map<String, dynamic> _rowFor(String uid, ReadEntry e, String profileId) => {
    'user_key': uid,
    if (profileId != kDefaultProfileId) 'profile_id': profileId,
    'source_id': e.sourceId,
    'show_id': e.showId,
    'title': e.title,
    'cover': e.cover,
    'chapter_id': e.chapterId,
    'chapter_number': e.chapterNumber,
    'chapter_url': e.chapterUrl,
    'pos': e.pos,
    'total': e.total,
    'updated_ms': e.updatedMs,
    'type': e.type.name,
  };

  Future<void> _pushToCloud(
    String key,
    ReadEntry e,
    String profileId, {
    bool force = false,
  }) async {
    final uid = _currentUserId();
    if (uid == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastCloudPush[key] ?? 0;
    if (!force && now - last < _cloudThrottleMs) return;
    _lastCloudPush[key] = now;
    try {
      await _remote.upsert(_rowFor(uid, e, profileId));
    } catch (_) {
      /* best-effort — missing table / offline degrades silently */
    }
  }

  ReadEntry _fromMap(Map raw) =>
      ReadEntry.fromJson(Map<String, dynamic>.from(raw));

  /// Newest-first, excluding finished chapters (the Continue Reading feed).
  /// [type] filters to one kind (manga or novel) — the box mixes both, so the
  /// Continue Reading row passes the current mode's type to avoid showing manga
  /// under Novel and vice versa. Filtering happens BEFORE [limit] so a busy
  /// other-kind history can't crowd this kind out of the row.
  List<ReadEntry> recent({int limit = 20, ProviderType? type}) {
    final all =
        _entriesFor(_profileId)
            .where((e) => !e.finished && (type == null || e.type == type))
            .toList()
          ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
    return all.take(limit).toList();
  }

  /// Every read title, newest-first, including finished ones — backs both the
  /// full reading-History screen and [pushAllLocalToCloud]'s library backup,
  /// not just the unfinished subset [recent] surfaces. The box mixes manga and
  /// novel; callers filter on [ReadEntry.type].
  List<ReadEntry> all() {
    return _entriesFor(_profileId)
      ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
  }

  List<ReadEntry> _entriesFor(String profileId) => [
    for (final key in _box.keys)
      if (profileOwnsKey(key, profileId)) _fromMap(_box.get(key)!),
  ];

  /// Notifies the Home "Continue Reading" row on any local change.
  ValueListenable<Box> listenable() => _box.listenable();

  /// Uploads local reading history to the cloud under the current account,
  /// newest-wins — see [WatchHistory.pushAllLocalToCloud] for the full
  /// rationale. Additive, never deletes.
  Future<({int pushed, int failed})> pushAllLocalToCloud() async {
    final uid = _currentUserId();
    if (uid == null) return (pushed: 0, failed: 0);
    final profileId = _profileId;
    final cloudTimes = <String, int>{};
    var readOk = true;
    try {
      for (final m in await _remote.listFor(
        uid,
        profileId: _remoteProfileId(profileId),
      )) {
        cloudTimes[_key('${m['source_id']}', '${m['show_id']}', profileId)] =
            (m['updated_ms'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      readOk = false;
    }
    var pushed = 0, failed = 0;
    for (final e in _entriesFor(profileId)) {
      final key = _key(e.sourceId, e.showId, profileId);
      final cloudT = cloudTimes[key];
      if (cloudT != null && cloudT >= e.updatedMs) continue;
      try {
        await _remote.upsert(_rowFor(uid, e, profileId));
        pushed++;
      } catch (_) {
        failed++;
      }
    }
    if (!readOk) failed++;
    return (pushed: pushed, failed: failed);
  }

  /// One-time-per-account backfill, run before the first (destructive) merge
  /// pull — see [WatchHistory.seedCloudIfNeeded].
  Future<void> seedCloudIfNeeded() async {
    final uid = _currentUserId();
    if (uid == null || !Hive.isBoxOpen(syncMetaBox)) return;
    final box = Hive.box(syncMetaBox);
    final profileId = _profileId;
    final flag = profileScopedKey(profileId, '$_seedFlagPrefix$uid');
    if (box.get(flag) == true) return;
    final r = await pushAllLocalToCloud();
    if (r.failed == 0) await box.put(flag, true);
  }

  /// Merge the signed-in user's cloud reading history into the local cache,
  /// newest-wins, non-destructive — see [WatchHistory.pullFromCloud] for the
  /// full rationale (an empty/sparse cloud must never wipe local progress).
  Future<void> pullFromCloud({String? forProfileId}) async {
    final uid = _currentUserId();
    if (uid == null) return;
    final profileId = forProfileId ?? _profileId;
    try {
      final profile = _remoteProfileId(profileId);
      final pages = await Future.wait([
        _remote.pageFor(
          uid,
          profileId: profile,
          type: ProviderType.manga,
          offset: 0,
        ),
        _remote.pageFor(
          uid,
          profileId: profile,
          type: ProviderType.novel,
          offset: 0,
        ),
      ]);
      await _mergeCloudRows(pages.expand((page) => page).toList(), profileId);
      for (final (type, rows) in [
        (ProviderType.manga, pages[0]),
        (ProviderType.novel, pages[1]),
      ]) {
        final pageState = _cloudPageState(uid, profileId, type);
        final oldOffset = pageState['offset'] as int? ?? 0;
        await _saveCloudPageState(
          uid,
          profileId,
          type,
          offset: oldOffset < rows.length ? rows.length : oldOffset,
          hasMore: rows.length == ReadingHistoryRemote.pageSize,
        );
      }
      _markPulled(profileId);
    } catch (_) {
      /* keep local — missing table / offline degrades silently */
    }
  }

  Future<bool> loadMoreFromCloud(
    ProviderType type, {
    String? forProfileId,
  }) async {
    final uid = _currentUserId();
    if (uid == null) return false;
    final profileId = forProfileId ?? _profileId;
    final state = _cloudPageState(uid, profileId, type);
    if (state['hasMore'] == false) return false;
    final offset = state['offset'] as int? ?? 0;
    try {
      final rows = await _remote.pageFor(
        uid,
        profileId: _remoteProfileId(profileId),
        type: type,
        offset: offset,
      );
      await _mergeCloudRows(rows, profileId);
      final hasMore = rows.length == ReadingHistoryRemote.pageSize;
      await _saveCloudPageState(
        uid,
        profileId,
        type,
        offset: offset + rows.length,
        hasMore: hasMore,
      );
      return hasMore;
    } catch (_) {
      return true; // Keep the same cursor so the next scroll can retry.
    }
  }

  Future<void> _mergeCloudRows(
    List<Map<String, dynamic>> rows,
    String profileId,
  ) async {
    for (final m in rows) {
      final key = _key('${m['source_id']}', '${m['show_id']}', profileId);
      final cloudUpdated = (m['updated_ms'] as num?)?.toInt() ?? 0;
      final localUpdated = (_box.get(key)?['updatedMs'] as num?)?.toInt() ?? -1;
      if (cloudUpdated <= localUpdated) continue;
      await _box.put(key, {
        'sourceId': m['source_id'],
        'showId': m['show_id'],
        'title': m['title'],
        'cover': m['cover'],
        'chapterId': m['chapter_id'],
        'chapterNumber': m['chapter_number'],
        'chapterUrl': m['chapter_url'],
        'pos': m['pos'],
        'total': m['total'],
        'updatedMs': m['updated_ms'],
        'type': m['type'],
      });
    }
  }

  /// Pull from cloud only when the last successful pull is older than
  /// [maxAge] — see [WatchHistory.pullFromCloudIfStale]. Keeps app launches
  /// from re-downloading Continue Reading that's already cached locally.
  Future<void> pullFromCloudIfStale({
    Duration maxAge = const Duration(hours: 12),
  }) async {
    if (_currentUserId() == null) return;
    final profileId = _profileId;
    int? last;
    if (Hive.isBoxOpen(syncMetaBox)) {
      last =
          Hive.box(syncMetaBox).get(profileScopedKey(profileId, _syncMetaKey))
              as int?;
    }
    if (last != null) {
      final age = DateTime.now().millisecondsSinceEpoch - last;
      if (age >= 0 && age < maxAge.inMilliseconds) return; // still fresh
    }
    await pullFromCloud(forProfileId: profileId);
  }

  void _markPulled(String profileId) {
    if (Hive.isBoxOpen(syncMetaBox)) {
      Hive.box(syncMetaBox).put(
        profileScopedKey(profileId, _syncMetaKey),
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  /// Look up the saved entry for one title — the cloud-synced "last read
  /// chapter", which the Read button falls back to when [ReadStore] (this
  /// reader's own per-chapter positions, local-only) has no mark yet, e.g. a
  /// title read on another device. Same key as [remove].
  ReadEntry? get(String sourceId, String showId) {
    final raw = _box.get(_key(sourceId, showId));
    return raw == null ? null : _fromMap(raw);
  }

  Future<ReadEntry?> refreshFromCloud(String sourceId, String showId) async {
    final uid = _currentUserId();
    if (uid == null) return get(sourceId, showId);
    try {
      final row = await _remote.getFor(
        uid,
        profileId: _remoteProfileId(_profileId),
        sourceId: sourceId,
        showId: showId,
      );
      if (row != null) await _mergeCloudRows([row], _profileId);
    } catch (_) {
      // A missing row or offline detail screen stays local-only.
    }
    return get(sourceId, showId);
  }

  /// Remove a single title from reading history, locally and (when signed in)
  /// from the cloud so it doesn't sync back — see [WatchHistory.remove].
  Future<void> remove(String sourceId, String showId) async {
    final profileId = _profileId;
    final key = _key(sourceId, showId, profileId);
    await _box.delete(key);
    _lastCloudPush.remove(key);
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      await _remote.deleteRow(
        uid,
        sourceId,
        showId,
        profileId: _remoteProfileId(profileId),
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// User-initiated "Clear history" for ONE kind (manga or novel): wipe those
  /// rows everywhere — local AND cloud — so a later pull can't restore them,
  /// while leaving the other kind untouched (both live in this one box/table).
  /// Deletes the cloud rows first so even a racing pull sees nothing.
  Future<void> clearType(ProviderType type) async {
    final uid = _currentUserId();
    final profileId = _profileId;
    if (uid != null) {
      try {
        await _remote.deleteAllForType(
          uid,
          type.name,
          profileId: _remoteProfileId(profileId),
        );
      } catch (_) {
        /* best-effort — local still clears */
      }
    }
    final keys = _box.keys.where((k) {
      if (!profileOwnsKey(k, profileId)) return false;
      final raw = _box.get(k);
      return raw != null &&
          readEntryTypeFromName(raw['type'] as String?) == type;
    }).toList();
    for (final k in keys) {
      await _box.delete(k);
      _lastCloudPush.remove(k);
    }
    if (uid != null && Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_cloudPageKey(uid, profileId, type));
    }
  }

  /// Drop the local cache only — see [WatchHistory.clearLocal]. The cloud
  /// copy is the user's data and MUST survive, so this must never touch the
  /// cloud.
  Future<void> clearLocal() async {
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      final meta = Hive.box(syncMetaBox);
      for (final key
          in meta.keys
              .where(
                (k) =>
                    '$k' == _syncMetaKey ||
                    '$k'.startsWith('p:') ||
                    '$k'.contains(_cloudPagePrefix),
              )
              .toList()) {
        await meta.delete(key);
      }
    }
  }
}
