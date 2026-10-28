import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestClient;

import '../hive/safe_box.dart';
import '../supabase/cloud_postgrest.dart';
import '../supabase/supabase_service.dart';
import '../theme/theme_controller.dart';
import 'profile_scope.dart';

export 'profile_scope.dart' show kDefaultProfileId;

class ViewerProfile {
  const ViewerProfile({
    required this.id,
    required this.name,
    this.bio = '',
    this.avatar = 0,
    this.isKids = false,
    this.photoUrl,
    this.coverUrl,
    this.accentColor,
    this.materialYou,
    this.amoled,
  });

  final String id;
  final String name;
  final String bio;
  final int avatar;
  final bool isKids;
  final String? photoUrl;
  final String? coverUrl;
  final int? accentColor;
  final bool? materialYou;
  final bool? amoled;

  bool get isDefault => id == kDefaultProfileId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'bio': bio,
    'avatar': avatar,
    'isKids': isKids,
    'photoUrl': photoUrl,
    'coverUrl': coverUrl,
    'accentColor': accentColor,
    'materialYou': materialYou,
    'amoled': amoled,
  };

  factory ViewerProfile.fromJson(Map<String, dynamic> json) => ViewerProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    bio: json['bio'] as String? ?? '',
    avatar: (json['avatar'] as num?)?.toInt() ?? 0,
    isKids: json['isKids'] == true,
    photoUrl: json['photoUrl'] as String?,
    coverUrl: json['coverUrl'] as String?,
    accentColor: (json['accentColor'] as num?)?.toInt(),
    materialYou: json['materialYou'] as bool?,
    amoled: json['amoled'] as bool?,
  );

  ViewerProfile copyWith({
    String? name,
    String? bio,
    int? avatar,
    bool? isKids,
    String? photoUrl,
    String? coverUrl,
    int? accentColor,
    bool? materialYou,
    bool? amoled,
    bool clearPhotoUrl = false,
    bool clearCoverUrl = false,
  }) => ViewerProfile(
    id: id,
    name: name ?? this.name,
    bio: bio ?? this.bio,
    avatar: avatar ?? this.avatar,
    isKids: isKids ?? this.isKids,
    photoUrl: clearPhotoUrl ? null : photoUrl ?? this.photoUrl,
    coverUrl: clearCoverUrl ? null : coverUrl ?? this.coverUrl,
    accentColor: accentColor ?? this.accentColor,
    materialYou: materialYou ?? this.materialYou,
    amoled: amoled ?? this.amoled,
  );
}

class ViewerProfileRemote {
  ViewerProfileRemote(
    SupabaseService service, {
    PostgrestClient? vpsClient,
    String? Function()? accessToken,
  }) : _cloud = CloudPostgrest(
         service,
         vpsClient: vpsClient,
         accessToken: accessToken,
       );

  final CloudPostgrest _cloud;

  Future<List<Map<String, dynamic>>> listFor(String userId) async {
    final rows = await _cloud
        .from('viewer_profiles')
        .select()
        .eq('user_key', userId)
        .order('created_at');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<void> upsert(String userId, ViewerProfile profile) async {
    await _cloud.from('viewer_profiles').upsert({
      'user_key': userId,
      'profile_id': profile.id,
      'name': profile.name,
      'bio': profile.bio,
      'avatar': profile.avatar,
      'is_kids': profile.isKids,
      'photo_url': profile.photoUrl,
      // NULL means an older client omitted this field; '' means remove it.
      'cover_url': profile.coverUrl ?? '',
      'accent_color': profile.accentColor,
      'material_you': profile.materialYou,
      'amoled': profile.amoled,
    });
  }

  Future<void> delete(String userId, String profileId) async {
    await _cloud.from('viewer_profiles').delete().match({
      'user_key': userId,
      'profile_id': profileId,
    });
  }
}

enum _PendingProfileWrite { create, update }

/// Profiles belong to the signed-in account. Library stores read [activeId]
/// at call time so the existing player and reader APIs do not change.
class ViewerProfileStore {
  ViewerProfileStore({
    ViewerProfileRemote? remote,
    String? Function()? currentUserId,
    Future<bool> Function(String url)? deleteAvatar,
    this.onProfileDataDeleted,
  }) : _remote = remote,
       _currentUserId = currentUserId,
       _deleteAvatar = deleteAvatar;

  static const int maxProfiles = 4;
  static const int maxNameLength = 24;
  static const int maxBioLength = 160;
  static const String boxName = 'viewer_profiles';
  static const String askOnLaunchKey = 'ask_on_launch';

  final ViewerProfileRemote? _remote;
  final String? Function()? _currentUserId;
  final Future<bool> Function(String url)? _deleteAvatar;
  final Future<void> Function(String owner, String profileId)?
  onProfileDataDeleted;
  int _loadRequest = 0;
  String? _loadedOwner;
  List<ViewerProfile> _profiles = const [];
  final ValueNotifier<ViewerProfile?> active = ValueNotifier(null);
  final ValueNotifier<int> revision = ValueNotifier(0);
  final ValueNotifier<int> contextRevision = ValueNotifier(0);

  List<ViewerProfile> get profiles => List.unmodifiable(_profiles);
  List<ViewerProfile> get recoverableProfiles =>
      List.unmodifiable(_readProfiles(_recoveryKey(_loadedOwner ?? _owner)));
  ViewerProfile get activeProfile =>
      active.value ?? const ViewerProfile(id: kDefaultProfileId, name: 'Home');
  String get activeId => activeProfile.id;
  String get ownerKey => _loadedOwner ?? _owner;
  bool get adultMetadataAllowed => !activeProfile.isKids;
  bool get isLoadedForCurrentUser => _loadedOwner == _owner;
  bool get askOnLaunch => _box.get(askOnLaunchKey, defaultValue: true) as bool;

  Future<void> setAskOnLaunch(bool value) async {
    await _box.put(askOnLaunchKey, value);
    revision.value++;
  }

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  String get _owner => _currentUserId?.call() ?? 'local';
  String _profilesKey(String owner) => 'profiles:$owner';
  String _activeKey(String owner) => 'active:$owner';
  String _pendingKey(String owner) => 'pending:$owner';
  String _recoveryKey(String owner) => 'recoverable:$owner';

  Map<String, _PendingProfileWrite> _pending(String owner) {
    final raw = _box.get(_pendingKey(owner));
    if (raw is Map) {
      final pending = <String, _PendingProfileWrite>{};
      for (final entry in raw.entries) {
        final id = entry.key;
        final operation = entry.value;
        if (id is! String || operation is! String) continue;
        if (operation == 'create') {
          pending[id] = _PendingProfileWrite.create;
        } else if (operation == 'update') {
          pending[id] = _PendingProfileWrite.update;
        }
      }
      return pending;
    }
    // Preserve queued offline profiles from the earlier, unreleased test build.
    if (raw is List) {
      return {
        for (final id in raw.whereType<String>())
          id: _PendingProfileWrite.create,
      };
    }
    return {};
  }

  Future<void> _setPending(
    String owner,
    String id,
    _PendingProfileWrite? operation,
  ) async {
    final pending = _pending(owner);
    if (operation == null) {
      pending.remove(id);
    } else {
      // A profile created offline must remain a create even if edited again
      // before its first successful upload.
      if (operation == _PendingProfileWrite.create ||
          pending[id] != _PendingProfileWrite.create) {
        pending[id] = operation;
      }
    }
    await _box.put(_pendingKey(owner), {
      for (final entry in pending.entries) entry.key: entry.value.name,
    });
  }

  Future<void> loadForUser({String displayName = 'Home'}) async {
    final request = ++_loadRequest;
    final userId = _currentUserId?.call();
    final owner = userId ?? 'local';

    final local = _readLocal(owner);
    final recoverable = _readProfiles(_recoveryKey(owner));
    final next = local.isEmpty ? [_defaultProfile(displayName)] : local;
    // Local first: boot (and the splash) never waits on the network. The
    // cloud merge below re-applies over this when it arrives.
    await _finishLoad(
      recoverable: recoverable,
      next: next,
      owner: owner,
      displayName: displayName,
      request: request,
    );

    final remote = _remote;
    if (userId == null || remote == null) return;
    try {
      await _mergeRemote(
        remote: remote,
        userId: userId,
        local: local,
        recoverable: recoverable,
        owner: owner,
        displayName: displayName,
        request: request,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Offline or too slow: the local list applied above stays.
    }
  }

  /// Cloud half of [loadForUser]: merge remote profiles over the locally
  /// applied list, push pending writes, then re-apply. Runs bounded (see the
  /// timeout at the call site) so a dead network can't trap boot.
  Future<void> _mergeRemote({
    required ViewerProfileRemote remote,
    required String userId,
    required List<ViewerProfile> local,
    required List<ViewerProfile> recoverable,
    required String owner,
    required String displayName,
    required int request,
  }) async {
    bool isCurrentLoad() => request == _loadRequest && owner == _owner;
    var mergedRecoverable = recoverable;
    try {
      final rows = await remote.listFor(userId);
      if (!isCurrentLoad()) return;
      final cloud = [
        for (final row in rows)
          if (_validRemoteProfile(row)) _fromRemote(row),
      ];
      final pending = _pending(owner);
      final cloudIds = cloud.map((profile) => profile.id).toSet();
      mergedRecoverable = {
        for (final profile in recoverable)
          if (!cloudIds.contains(profile.id)) profile.id: profile,
        for (final profile in local)
          if (profile.id != kDefaultProfileId &&
              !cloudIds.contains(profile.id) &&
              pending[profile.id] == null)
            profile.id: profile,
      }.values.toList();
      final unsynced = [
        for (final profile in local)
          if (pending[profile.id] == _PendingProfileWrite.create ||
              (pending[profile.id] == _PendingProfileWrite.update &&
                  cloudIds.contains(profile.id)))
            profile,
      ];
      final deletedWhileOffline = [
        for (final profile in local)
          if (profile.id != kDefaultProfileId &&
              pending[profile.id] == _PendingProfileWrite.update &&
              !cloudIds.contains(profile.id))
            profile.id,
      ];
      var merged = {
        for (final profile in cloud) profile.id: profile,
        for (final profile in unsynced) profile.id: profile,
      }.values.toList();
      if (!merged.any((p) => p.id == kDefaultProfileId)) {
        final fallback =
            local.where((p) => p.id == kDefaultProfileId).firstOrNull ??
            _defaultProfile(displayName);
        merged.insert(0, fallback);
        await remote.upsert(userId, fallback);
        if (!isCurrentLoad()) return;
      }
      for (final profileId in deletedWhileOffline) {
        await _deleteLocalProfileData(profileId);
        await _setPending(owner, profileId, null);
      }
      for (final profile in unsynced) {
        await remote.upsert(userId, profile);
        if (!isCurrentLoad()) return;
        await _setPending(owner, profile.id, null);
      }
      await _finishLoad(
        recoverable: mergedRecoverable,
        next: merged,
        owner: owner,
        displayName: displayName,
        request: request,
      );
    } catch (_) {
      // Offline: the local list applied by loadForUser stays.
      return;
    }
  }

  /// Applies a profile list: guarantees a default profile first, persists the
  /// recovery + local copies, then picks the active profile and theme.
  /// Idempotent — [loadForUser] runs it for local data first, then again
  /// after a cloud merge arrives.
  Future<void> _finishLoad({
    required List<ViewerProfile> recoverable,
    required List<ViewerProfile> next,
    required String owner,
    required String displayName,
    required int request,
  }) async {
    bool isCurrentLoad() => request == _loadRequest && owner == _owner;
    final result = [...next];
    // Do not trim older profiles to make room for Home; let users remove them.
    if (!result.any((p) => p.id == kDefaultProfileId)) {
      result.insert(0, _defaultProfile(displayName));
    }
    final defaultIndex = result.indexWhere((p) => p.id == kDefaultProfileId);
    if (defaultIndex > 0) result.insert(0, result.removeAt(defaultIndex));
    if (!isCurrentLoad()) return;
    await _box.put(_recoveryKey(owner), [
      for (final profile in recoverable) profile.toJson(),
    ]);
    if (!isCurrentLoad()) return;
    await _saveLocal(owner, result);
    if (!isCurrentLoad()) return;
    _loadedOwner = owner;
    _profiles = result;
    final storedId = _box.get(_activeKey(owner)) as String?;
    final chosen =
        result.where((p) => p.id == storedId).firstOrNull ??
        result.firstWhere((p) => p.id == kDefaultProfileId);
    active.value = chosen;
    await _applyTheme(chosen);
    revision.value++;
  }

  Future<ViewerProfile?> create(
    String name, {
    String bio = '',
    int avatar = 0,
    bool isKids = false,
    String? photoUrl,
    String? coverUrl,
  }) async {
    final normalized = name.trim();
    if (!_validName(normalized) ||
        bio.trim().runes.length > maxBioLength ||
        _profiles.length >= maxProfiles) {
      return null;
    }
    final profile = ViewerProfile(
      id: _uuidV4(),
      name: normalized,
      bio: bio.trim(),
      avatar: avatar.clamp(0, 11).toInt(),
      isKids: isKids,
      photoUrl: photoUrl,
      coverUrl: coverUrl,
    );
    _profiles = [..._profiles, profile];
    await _saveLocal(_loadedOwner ?? _owner);
    await _saveRemote(profile, operation: _PendingProfileWrite.create);
    revision.value++;
    return profile;
  }

  Future<bool> restoreRecoverable(String profileId) async {
    final owner = _loadedOwner;
    final remote = _remote;
    if (owner == null ||
        owner != _owner ||
        remote == null ||
        _currentUserId?.call() == null ||
        _profiles.length >= maxProfiles) {
      return false;
    }
    final recoverable = _readProfiles(_recoveryKey(owner));
    final profile = recoverable.where((p) => p.id == profileId).firstOrNull;
    if (profile == null) return false;
    try {
      await remote.upsert(owner, profile);
    } catch (_) {
      return false;
    }
    if (owner != _owner) return false;
    _profiles = [..._profiles, profile];
    await _saveLocal(owner);
    await _box.put(_recoveryKey(owner), [
      for (final candidate in recoverable)
        if (candidate.id != profileId) candidate.toJson(),
    ]);
    revision.value++;
    return true;
  }

  Future<bool> rename(String profileId, String name) async {
    final normalized = name.trim();
    if (!_validName(normalized) || !_profiles.any((p) => p.id == profileId)) {
      return false;
    }
    _profiles = [
      for (final profile in _profiles)
        if (profile.id == profileId)
          profile.copyWith(name: normalized)
        else
          profile,
    ];
    await _saveLocal(_loadedOwner ?? _owner);
    final synced = await _saveRemote(
      _profiles.firstWhere((p) => p.id == profileId),
    );
    _refreshActive(profileId);
    return synced;
  }

  Future<bool> update(
    String profileId, {
    String? bio,
    int? avatar,
    bool? isKids,
    String? photoUrl,
    bool clearPhotoUrl = false,
    String? coverUrl,
    bool clearCoverUrl = false,
  }) async {
    final index = _profiles.indexWhere((p) => p.id == profileId);
    if (index < 0 || (bio != null && bio.trim().runes.length > maxBioLength)) {
      return false;
    }
    final profile = _profiles[index].copyWith(
      bio: bio?.trim(),
      avatar: avatar?.clamp(0, 11).toInt(),
      isKids: isKids,
      photoUrl: photoUrl,
      clearPhotoUrl: clearPhotoUrl,
      coverUrl: coverUrl,
      clearCoverUrl: clearCoverUrl,
    );
    final activePolicyChanged =
        activeId == profileId && _profiles[index].isKids != profile.isKids;
    _profiles = [
      for (var i = 0; i < _profiles.length; i++)
        if (i == index) profile else _profiles[i],
    ];
    await _saveLocal(_loadedOwner ?? _owner);
    final synced = await _saveRemote(profile);
    _refreshActive(profileId);
    if (activePolicyChanged) contextRevision.value++;
    return synced;
  }

  Future<bool> updateTheme(
    String profileId, {
    int? accentColor,
    bool? materialYou,
    bool? amoled,
  }) async {
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0) return false;
    final profile = _profiles[index].copyWith(
      accentColor: accentColor,
      materialYou: materialYou,
      amoled: amoled,
    );
    _profiles = [
      for (var i = 0; i < _profiles.length; i++)
        if (i == index) profile else _profiles[i],
    ];
    await _saveLocal(_loadedOwner ?? _owner);
    if (activeId == profileId) {
      active.value = profile;
      await _applyTheme(profile);
    }
    revision.value++;
    return _saveRemote(profile);
  }

  Future<void> switchTo(String profileId) async {
    final profile = _profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null || profile.id == activeId) return;
    final owner = _loadedOwner ?? _owner;
    await _applyTheme(profile);
    if (owner != _owner || owner != (_loadedOwner ?? _owner)) return;
    active.value = profile;
    await _box.put(_activeKey(owner), profile.id);
    revision.value++;
    contextRevision.value++;
  }

  Future<bool> delete(String profileId) async {
    if (profileId == kDefaultProfileId ||
        _profiles.length <= 1 ||
        !_profiles.any((profile) => profile.id == profileId)) {
      return false;
    }
    final profile = _profiles.firstWhere((profile) => profile.id == profileId);
    final photoUrl = profile.photoUrl;
    final coverUrl = profile.coverUrl;
    final photoIsShared =
        photoUrl != null &&
        _profiles.any(
          (other) => other.id != profileId && other.photoUrl == photoUrl,
        );
    final userId = _currentUserId?.call();
    if (userId != null && _remote != null) {
      try {
        await _remote.delete(userId, profileId);
      } catch (_) {
        return false;
      }
    }
    _profiles = _profiles.where((p) => p.id != profileId).toList();
    revision.value++;
    if (activeId == profileId) await switchTo(kDefaultProfileId);
    await _deleteLocalProfileData(profileId);
    await _saveLocal(_loadedOwner ?? _owner);
    await _setPending(_loadedOwner ?? _owner, profileId, null);
    await onProfileDataDeleted?.call(_loadedOwner ?? _owner, profileId);
    if (photoUrl != null && !photoIsShared) {
      try {
        await _deleteAvatar?.call(photoUrl);
      } catch (_) {}
    }
    if (coverUrl != null &&
        coverUrl != photoUrl &&
        !_profiles.any(
          (other) => other.photoUrl == coverUrl || other.coverUrl == coverUrl,
        )) {
      try {
        await _deleteAvatar?.call(coverUrl);
      } catch (_) {}
    }
    return true;
  }

  Future<void> _deleteLocalProfileData(String profileId) async {
    final prefix = profileScopePrefix(profileId);
    for (final name in [
      'my_list',
      'watch_history',
      'read_history',
      'resume_positions',
      'read_positions',
      'list_status',
      'list_categories',
      'library_sync_meta',
    ]) {
      if (!Hive.isBoxOpen(name)) continue;
      final box = Hive.box(name);
      for (final key in box.keys.toList()) {
        if (key is String && key.startsWith(prefix)) await box.delete(key);
      }
    }
  }

  bool _validName(String name) =>
      name.isNotEmpty && name.length <= maxNameLength;

  ViewerProfile _defaultProfile(String name) => ViewerProfile(
    id: kDefaultProfileId,
    name: name.trim().isEmpty
        ? 'Home'
        : name.trim().substring(0, min(name.trim().length, maxNameLength)),
  );

  bool _validRemoteProfile(Map<String, dynamic> row) =>
      row['profile_id'] is String &&
      row['name'] is String &&
      (row['name'] as String).trim().isNotEmpty;

  ViewerProfile _fromRemote(Map<String, dynamic> row) => ViewerProfile(
    id: row['profile_id'] as String,
    name: row['name'] as String,
    bio: row['bio'] as String? ?? '',
    avatar: (row['avatar'] as num?)?.toInt() ?? 0,
    isKids: row['is_kids'] == true,
    photoUrl: row['photo_url'] as String?,
    coverUrl: (row['cover_url'] as String?)?.isNotEmpty == true
        ? row['cover_url'] as String
        : null,
    accentColor: (row['accent_color'] as num?)?.toInt(),
    materialYou: row['material_you'] as bool?,
    amoled: row['amoled'] as bool?,
  );

  Future<void> _applyTheme(ViewerProfile profile) =>
      ThemeController.applyProfileTheme(
        accentColor: profile.accentColor,
        materialYou: profile.materialYou,
        amoled: profile.amoled,
      );

  List<ViewerProfile> _readLocal(String owner) =>
      _readProfiles(_profilesKey(owner));

  List<ViewerProfile> _readProfiles(String key) {
    final raw = _box.get(key);
    if (raw is! List) return const [];
    final profiles = <ViewerProfile>[];
    for (final value in raw) {
      if (value is! Map) continue;
      try {
        profiles.add(ViewerProfile.fromJson(Map<String, dynamic>.from(value)));
      } catch (_) {
        // Ignore one malformed cached profile without losing the rest.
      }
    }
    return profiles;
  }

  Future<void> _saveLocal(String owner, [List<ViewerProfile>? profiles]) =>
      _box.put(_profilesKey(owner), [
        for (final profile in profiles ?? _profiles) profile.toJson(),
      ]);

  Future<bool> _saveRemote(
    ViewerProfile profile, {
    _PendingProfileWrite operation = _PendingProfileWrite.update,
  }) async {
    final userId = _currentUserId?.call();
    final remote = _remote;
    if (userId == null || remote == null) return true;
    try {
      await remote.upsert(userId, profile);
      await _setPending(userId, profile.id, null);
      return true;
    } catch (_) {
      await _setPending(userId, profile.id, operation);
      return false;
    }
  }

  void _refreshActive(String profileId) {
    if (activeId == profileId) {
      active.value = _profiles.firstWhere((p) => p.id == profileId);
    }
    revision.value++;
  }
}

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
