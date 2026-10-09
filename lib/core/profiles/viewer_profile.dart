import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../supabase/supabase_service.dart';
import 'profile_scope.dart';

export 'profile_scope.dart' show kDefaultProfileId;

class ViewerProfile {
  const ViewerProfile({
    required this.id,
    required this.name,
    this.avatar = 0,
    this.isKids = false,
    this.photoUrl,
  });

  final String id;
  final String name;
  final int avatar;
  final bool isKids;
  final String? photoUrl;

  bool get isDefault => id == kDefaultProfileId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatar': avatar,
    'isKids': isKids,
    'photoUrl': photoUrl,
  };

  factory ViewerProfile.fromJson(Map<String, dynamic> json) => ViewerProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    avatar: (json['avatar'] as num?)?.toInt() ?? 0,
    isKids: json['isKids'] == true,
    photoUrl: json['photoUrl'] as String?,
  );

  ViewerProfile copyWith({
    String? name,
    int? avatar,
    bool? isKids,
    String? photoUrl,
  }) => ViewerProfile(
    id: id,
    name: name ?? this.name,
    avatar: avatar ?? this.avatar,
    isKids: isKids ?? this.isKids,
    photoUrl: photoUrl ?? this.photoUrl,
  );
}

class ViewerProfileRemote {
  ViewerProfileRemote(this._service);

  final SupabaseService _service;

  Future<List<Map<String, dynamic>>> listFor(String userId) async {
    final rows = await _service.client
        .from('viewer_profiles')
        .select()
        .eq('user_key', userId)
        .order('created_at');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<void> upsert(String userId, ViewerProfile profile) async {
    await _service.client.from('viewer_profiles').upsert({
      'user_key': userId,
      'profile_id': profile.id,
      'name': profile.name,
      'avatar': profile.avatar,
      'is_kids': profile.isKids,
      'photo_url': profile.photoUrl,
    });
  }

  Future<void> delete(String userId, String profileId) async {
    await _service.client.from('viewer_profiles').delete().match({
      'user_key': userId,
      'profile_id': profileId,
    });
  }
}

/// Profiles belong to the signed-in account. Library stores read [activeId]
/// at call time so the existing player and reader APIs do not change.
class ViewerProfileStore {
  ViewerProfileStore({
    ViewerProfileRemote? remote,
    String? Function()? currentUserId,
  }) : _remote = remote,
       _currentUserId = currentUserId;

  static const int maxProfiles = 4;
  static const int maxNameLength = 24;
  static const String boxName = 'viewer_profiles';
  static const String askOnLaunchKey = 'ask_on_launch';

  final ViewerProfileRemote? _remote;
  final String? Function()? _currentUserId;
  int _loadRequest = 0;
  String? _loadedOwner;
  List<ViewerProfile> _profiles = const [];
  final ValueNotifier<ViewerProfile?> active = ValueNotifier(null);
  final ValueNotifier<int> revision = ValueNotifier(0);
  final ValueNotifier<int> contextRevision = ValueNotifier(0);

  List<ViewerProfile> get profiles => List.unmodifiable(_profiles);
  ViewerProfile get activeProfile =>
      active.value ?? const ViewerProfile(id: kDefaultProfileId, name: 'Home');
  String get activeId => activeProfile.id;
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

  Future<void> loadForUser({String displayName = 'Home'}) async {
    final request = ++_loadRequest;
    final userId = _currentUserId?.call();
    final owner = userId ?? 'local';
    bool isCurrentLoad() => request == _loadRequest && owner == _owner;

    final local = _readLocal(owner);
    var next = local.isEmpty ? [_defaultProfile(displayName)] : local;
    final remote = _remote;
    if (userId != null && remote != null) {
      try {
        final rows = await remote.listFor(userId);
        if (!isCurrentLoad()) return;
        if (rows.isEmpty) {
          for (final profile in next) {
            await remote.upsert(userId, profile);
            if (!isCurrentLoad()) return;
          }
        } else {
          final cloud = [
            for (final row in rows)
              if (_validRemoteProfile(row)) _fromRemote(row),
          ];
          if (!cloud.any((p) => p.id == kDefaultProfileId)) {
            final fallback = _defaultProfile(displayName);
            cloud.insert(0, fallback);
            await remote.upsert(userId, fallback);
            if (!isCurrentLoad()) return;
          }
          final merged = {
            for (final p in local) p.id: p,
            for (final p in cloud) p.id: p,
          };
          // Keep profiles saved by older builds when the creation limit changes.
          next = merged.values.toList();
          for (final p in local.where((p) => !cloud.any((c) => c.id == p.id))) {
            await remote.upsert(userId, p);
            if (!isCurrentLoad()) return;
          }
        }
      } catch (_) {
        // Keep the local profile list usable during offline startup.
      }
    }
    // Do not trim older profiles to make room for Home; let users remove them.
    if (!next.any((p) => p.id == kDefaultProfileId)) {
      next.insert(0, _defaultProfile(displayName));
    }
    if (!isCurrentLoad()) return;
    await _saveLocal(owner, next);
    if (!isCurrentLoad()) return;
    _loadedOwner = owner;
    _profiles = next;
    final storedId = _box.get(_activeKey(owner)) as String?;
    final chosen =
        next.where((p) => p.id == storedId).firstOrNull ??
        next.firstWhere((p) => p.id == kDefaultProfileId);
    active.value = chosen;
    revision.value++;
  }

  Future<ViewerProfile?> create(
    String name, {
    int avatar = 0,
    bool isKids = false,
    String? photoUrl,
  }) async {
    final normalized = name.trim();
    if (!_validName(normalized) || _profiles.length >= maxProfiles) return null;
    final profile = ViewerProfile(
      id: _uuidV4(),
      name: normalized,
      avatar: avatar.clamp(0, 11).toInt(),
      isKids: isKids,
      photoUrl: photoUrl,
    );
    _profiles = [..._profiles, profile];
    await _saveLocal(_loadedOwner ?? _owner);
    await _saveRemote(profile);
    revision.value++;
    return profile;
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
    await _saveRemote(_profiles.firstWhere((p) => p.id == profileId));
    _refreshActive(profileId);
    return true;
  }

  Future<bool> update(
    String profileId, {
    int? avatar,
    bool? isKids,
    String? photoUrl,
  }) async {
    final index = _profiles.indexWhere((p) => p.id == profileId);
    if (index < 0) return false;
    final profile = _profiles[index].copyWith(
      avatar: avatar?.clamp(0, 11).toInt(),
      isKids: isKids,
      photoUrl: photoUrl,
    );
    final activePolicyChanged =
        activeId == profileId && _profiles[index].isKids != profile.isKids;
    _profiles = [
      for (var i = 0; i < _profiles.length; i++)
        if (i == index) profile else _profiles[i],
    ];
    await _saveLocal(_loadedOwner ?? _owner);
    await _saveRemote(profile);
    _refreshActive(profileId);
    if (activePolicyChanged) contextRevision.value++;
    return true;
  }

  Future<void> switchTo(String profileId) async {
    final profile = _profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null || profile.id == activeId) return;
    active.value = profile;
    await _box.put(_activeKey(_loadedOwner ?? _owner), profile.id);
    revision.value++;
    contextRevision.value++;
  }

  Future<bool> delete(String profileId) async {
    if (profileId == kDefaultProfileId || _profiles.length <= 1) return false;
    _profiles = _profiles.where((p) => p.id != profileId).toList();
    revision.value++;
    if (activeId == profileId) await switchTo(kDefaultProfileId);
    await _deleteLocalProfileData(profileId);
    await _saveLocal(_loadedOwner ?? _owner);
    final userId = _currentUserId?.call();
    if (userId != null && _remote != null) {
      try {
        await _remote.delete(userId, profileId);
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
    avatar: (row['avatar'] as num?)?.toInt() ?? 0,
    isKids: row['is_kids'] == true,
    photoUrl: row['photo_url'] as String?,
  );

  List<ViewerProfile> _readLocal(String owner) {
    final raw = _box.get(_profilesKey(owner));
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

  Future<void> _saveRemote(ViewerProfile profile) async {
    final userId = _currentUserId?.call();
    final remote = _remote;
    if (userId == null || remote == null) return;
    try {
      await remote.upsert(userId, profile);
    } catch (_) {
      // The local update remains available and will be uploaded at next load.
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
