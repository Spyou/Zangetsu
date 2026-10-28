import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'profile_lock_remote.dart';
import 'profile_lock_store.dart';

/// The VPS authorizes unlocks; this device stores only status and optional
/// device approval. The inherited local PIN reader is used for migration.
class SyncedProfileLockStore extends ProfileLockStore {
  SyncedProfileLockStore({
    required ProfileLockRemote remote,
    required String? Function() currentUserId,
    super.storage,
    super.biometrics,
    this.onGrantsChanged,
  }) : _remote = remote,
       _currentUserId = currentUserId,
       _secure = storage ?? const FlutterSecureStorage();

  final ProfileLockRemote _remote;
  final String? Function() _currentUserId;
  final FlutterSecureStorage _secure;
  final void Function(Map<String, String>)? onGrantsChanged;
  final _grants = <String, ({String token, int version, DateTime expires})>{};
  final _versions = <String, int>{};
  final _recoveryCodes = <String, String>{};
  String? _owner;

  Future<Map<String, dynamic>> _request(
    String action, {
    String? profileId,
    String? pin,
    String? newPin,
    String? secret,
  }) async {
    final owner = _checkOwner();
    if (owner == null) throw const ProfileLockException('sign_in_required');
    try {
      final result = await _remote.request(
        action,
        profileId: profileId,
        pin: pin,
        newPin: newPin,
        secret: secret,
      );
      if (_checkOwner() != owner) {
        throw const ProfileLockException('session_changed');
      }
      return result;
    } on ProfileLockException {
      rethrow;
    } catch (_) {
      throw const ProfileLockException('online_required');
    }
  }

  String? _checkOwner() {
    final owner = _currentUserId();
    if (owner != _owner) {
      _owner = owner;
      _grants.clear();
      _versions.clear();
      _recoveryCodes.clear();
      super.clearSwitchApprovals();
      onGrantsChanged?.call(const {});
    }
    return owner;
  }

  String _key(String kind, String profileId) {
    final owner = _checkOwner();
    if (owner == null) throw const ProfileLockException('sign_in_required');
    return 'synced_profile_${kind}_${Uri.encodeComponent(owner)}_${Uri.encodeComponent(profileId)}';
  }

  Map<String, String> get grantHeaders {
    _checkOwner();
    final now = DateTime.now().toUtc();
    return {
      for (final entry in _grants.entries)
        if (entry.value.expires.isAfter(now) &&
            entry.value.version == _versions[entry.key])
          entry.key: entry.value.token,
    };
  }

  Future<Map<String, dynamic>?> _read(String key) async {
    final raw = await _secure.read(key: key);
    if (raw == null) return null;
    final value = jsonDecode(raw);
    if (value is! Map) {
      throw const FormatException('Invalid profile lock status');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<void> _cacheStatus(String id, Map<String, dynamic> status) async {
    final owner = _checkOwner();
    final statusKey = _key('status', id);
    final deviceKey = _key('device', id);
    if (status['locked'] is! bool) {
      throw const ProfileLockException('invalid_response');
    }
    if (status['locked'] == false) {
      _versions.remove(id);
      await _secure.delete(key: deviceKey);
      if (_checkOwner() != owner) {
        throw const ProfileLockException('session_changed');
      }
    }
    final version = (status['version'] as num?)?.toInt();
    if (version != null) _versions[id] = version;
    if (status['locked'] == false || _grants[id]?.version != version) {
      _grants.remove(id);
      onGrantsChanged?.call(grantHeaders);
    }
    await _secure.write(
      key: statusKey,
      value: jsonEncode({'locked': status['locked'], 'version': version}),
    );
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
  }

  Future<Map<String, dynamic>> _status(String id) async {
    final owner = _checkOwner();
    if (owner == null) {
      throw const ProfileLockException('sign_in_required');
    }
    final result = await _request('status', profileId: id);
    await _cacheStatus(id, result);
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    return result;
  }

  @override
  Future<bool> isLocked(String profileId) async {
    if (_checkOwner() == null) {
      if (profileId == 'default') {
        final saved = await _secure.readAll();
        if (saved.containsKey('profile_lock_default')) {
          throw const ProfileLockException('sign_in_required');
        }
        for (final entry in saved.entries) {
          if (entry.key.startsWith('synced_profile_status_') &&
              entry.key.endsWith('_default')) {
            final status = jsonDecode(entry.value);
            if (status is! Map || status['locked'] != false) {
              throw const ProfileLockException('sign_in_required');
            }
          }
        }
      }
      return false;
    }
    // Cached status cannot tell us whether another device added a PIN.
    final status = await _status(profileId);
    return status['locked'] == true || await super.isLocked(profileId);
  }

  @override
  bool isUnlocked(String profileId) => grantHeaders.containsKey(profileId);

  @override
  void lockEntry(String profileId) {
    _checkOwner();
    _grants.remove(profileId);
    super.lockEntry(profileId);
    onGrantsChanged?.call(grantHeaders);
  }

  @override
  Future<bool> needsLegacyPin(String profileId) async =>
      await super.isLocked(profileId) &&
      (await _status(profileId))['locked'] == true;

  Future<void> _accept(String id, Map<String, dynamic> result) async {
    final owner = _checkOwner();
    await _cacheStatus(id, result);
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    final token = result['grant_token'] as String?;
    final expires = DateTime.tryParse(result['expires_at'] as String? ?? '');
    final version = (result['version'] as num?)?.toInt();
    if (token == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ||
        expires == null ||
        version == null ||
        !expires.isAfter(DateTime.now())) {
      throw const ProfileLockException('invalid_response');
    }
    _grants[id] = (token: token, version: version, expires: expires);
    final recovery = result['recovery_code'] as String?;
    if (recovery != null) _recoveryCodes[id] = recovery;
    onGrantsChanged?.call(grantHeaders);
  }

  @override
  Future<bool> verify(String profileId, String pin, {String? localPin}) async {
    try {
      final hasLegacy = await super.isLocked(profileId);
      final originalPin = localPin == null || localPin.trim().isEmpty
          ? pin
          : localPin.trim();
      if (hasLegacy && !await super.verify(profileId, originalPin)) {
        return false;
      }
      final status = await _status(profileId);
      Map<String, dynamic> result;
      if (status['locked'] == true) {
        result = await _request('unlock', profileId: profileId, pin: pin);
      } else {
        if (!hasLegacy) return false;
        // A local hash cannot be sent as a PIN. Enroll only after the user
        // supplies the original PIN and the VPS confirms it has been saved.
        result = await _request('set', profileId: profileId, newPin: pin);
      }
      await _accept(profileId, result);
      await super.clear(profileId);
      return true;
    } on ProfileLockException catch (error) {
      if (error.code == 'verification_failed') return false;
      rethrow;
    } catch (_) {
      throw const ProfileLockException('online_required');
    }
  }

  @override
  Future<bool> setPin(
    String profileId,
    String pin, {
    String? currentPin,
  }) async {
    if (!ProfileLockStore.isValidNewPin(pin)) return false;
    if (_checkOwner() == null) {
      throw const ProfileLockException('sign_in_required');
    }
    if (await super.isLocked(profileId) &&
        !await super.verify(profileId, currentPin ?? '')) {
      throw const ProfileLockException('verification_failed');
    }
    final result = await _request(
      'set',
      profileId: profileId,
      pin: currentPin,
      newPin: pin,
    );
    await _accept(profileId, result);
    await super.clear(profileId);
    await _secure.delete(key: _key('device', profileId));
    return true;
  }

  @override
  Future<void> clear(String profileId, {String? pin}) async {
    if (_checkOwner() == null) {
      throw const ProfileLockException('sign_in_required');
    }
    await _request('remove', profileId: profileId, pin: pin);
    _grants.remove(profileId);
    _versions.remove(profileId);
    _recoveryCodes.remove(profileId);
    await _cacheStatus(profileId, {'locked': false});
    await _secure.delete(key: _key('device', profileId));
    await super.clear(profileId);
  }

  @override
  String? takeRecoveryCode(String profileId) =>
      _recoveryCodes.remove(profileId);

  @override
  Future<bool> recover(
    String profileId,
    String code,
    String newPin, {
    String? localPin,
  }) async {
    if (!ProfileLockStore.isValidNewPin(newPin)) {
      throw const ProfileLockException('invalid_pin');
    }
    if (await super.isLocked(profileId) &&
        !await super.verify(profileId, localPin ?? '')) {
      throw const ProfileLockException('verification_failed');
    }
    if (_checkOwner() == null) {
      throw const ProfileLockException('sign_in_required');
    }
    final result = await _request(
      'recover',
      profileId: profileId,
      newPin: newPin,
      secret: code.trim().toLowerCase(),
    );
    await _accept(profileId, result);
    await super.clear(profileId);
    await _secure.delete(key: _key('device', profileId));
    return true;
  }

  @override
  Future<bool> biometricEnabled(String profileId) async {
    if (_checkOwner() == null) return false;
    final device = await _read(_key('device', profileId));
    return device?['token'] is String &&
        (!_versions.containsKey(profileId) ||
            device?['version'] == _versions[profileId]);
  }

  @override
  Future<bool> canUnlockWithBiometrics(String profileId) async =>
      !await super.isLocked(profileId) &&
      await biometricEnabled(profileId) &&
      await canUseBiometrics;

  @override
  Future<void> setBiometricEnabled(
    String profileId,
    bool enabled, {
    String? pin,
  }) async {
    final owner = _checkOwner();
    if (owner == null) {
      throw const ProfileLockException('sign_in_required');
    }
    final deviceKey = _key('device', profileId);
    if (!enabled) {
      final device = await _read(deviceKey);
      if (_checkOwner() != owner) {
        throw const ProfileLockException('session_changed');
      }
      await _secure.delete(key: deviceKey);
      if (_checkOwner() != owner) {
        throw const ProfileLockException('session_changed');
      }
      if (device?['token'] is String) {
        try {
          await _request(
            'device_remove',
            profileId: profileId,
            secret: device!['token'] as String,
          );
        } catch (_) {
          /* Local removal already disables this device. */
        }
      }
      return;
    }
    if (!await verify(profileId, pin ?? '')) {
      throw const ProfileLockException('verification_failed');
    }
    if (!await super.authenticateBiometric(
      'Confirm fingerprint access for this profile',
      profileId: profileId,
    )) {
      throw const ProfileLockException('biometric_cancelled');
    }
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    final result = await _request(
      'device_enroll',
      profileId: profileId,
      pin: pin,
    );
    final token = result['device_token'] as String?;
    if (token == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
      throw const ProfileLockException('invalid_response');
    }
    await _accept(profileId, result);
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    await _secure.write(
      key: deviceKey,
      value: jsonEncode({'token': token, 'version': result['version']}),
      iOptions: const IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
      mOptions: const MacOsOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
  }

  @override
  Future<bool> authenticateBiometric(String reason, {String? profileId}) async {
    final owner = _checkOwner();
    if (owner == null || profileId == null) return false;
    final deviceKey = _key('device', profileId);
    if (!await canUnlockWithBiometrics(profileId)) return false;
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    await _status(profileId);
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    if (!await canUnlockWithBiometrics(profileId)) return false;
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    if (!await super.authenticateBiometric(reason, profileId: profileId)) {
      return false;
    }
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    final device = await _read(deviceKey);
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    final result = await _request(
      'device_unlock',
      profileId: profileId,
      secret: device?['token'] as String?,
    );
    if (_checkOwner() != owner) {
      throw const ProfileLockException('session_changed');
    }
    await _accept(profileId, result);
    return true;
  }

  @override
  Future<void> forgetDeletedProfile(String owner, String profileId) async {
    final suffix =
        '${Uri.encodeComponent(owner)}_${Uri.encodeComponent(profileId)}';
    await _secure.delete(key: 'synced_profile_status_$suffix');
    await _secure.delete(key: 'synced_profile_device_$suffix');
    if (_checkOwner() == owner) {
      _versions.remove(profileId);
      _recoveryCodes.remove(profileId);
      lockEntry(profileId);
      await super.clear(profileId);
    }
  }

  Future<void> requireBackupAccess() async {
    final owner = _checkOwner();
    final saved = await _secure.readAll();
    final prefix = owner == null ? null : _key('status', '');
    for (final entry in saved.entries) {
      if (entry.key.startsWith('profile_lock_')) {
        throw const ProfileLockException('profile_locked');
      }
      if (!entry.key.startsWith('synced_profile_status_')) continue;
      final value = jsonDecode(entry.value);
      if (value is! Map || value['locked'] is! bool) {
        throw const ProfileLockException('invalid_response');
      }
      if (prefix == null || !entry.key.startsWith(prefix)) {
        throw const ProfileLockException('backup_other_account');
      }
    }
    if (owner == null) return;
    final status = await _request('status');
    final profiles = status['profiles'];
    if (profiles is! List) {
      throw const ProfileLockException('invalid_response');
    }
    for (final value in profiles) {
      if (value is! Map || value['profile_id'] is! String) {
        throw const ProfileLockException('invalid_response');
      }
      await _cacheStatus(
        value['profile_id'] as String,
        Map<String, dynamic>.from(value),
      );
    }
    await _request('backup_access');
  }
}
