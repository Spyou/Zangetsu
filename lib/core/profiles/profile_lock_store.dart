import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Legacy device-only PIN storage and the shared profile-lock interface.
/// Production uses SyncedProfileLockStore, which migrates a legacy PIN only
/// after the original PIN is verified and the VPS accepts its replacement.
///
/// Authentication is remembered for the active profile during this process.
/// Switching back to it still requires verification through the UI gate.
/// Biometric is a convenience shortcut; the PIN remains the fallback.
class ProfileLockStore {
  ProfileLockStore({
    FlutterSecureStorage? storage,
    LocalAuthentication? biometrics,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _biometrics = biometrics ?? LocalAuthentication();

  final FlutterSecureStorage _storage;
  final LocalAuthentication _biometrics;
  final Set<String> _unlocked = {};
  final Set<String> _switchApprovals = {};

  static bool isValidNewPin(String pin) =>
      (pin.length == 4 || pin.length == 6) &&
      pin.codeUnits.every((digit) => digit >= 48 && digit <= 57);

  static String _key(String profileId) => 'profile_lock_$profileId';

  /// A lock exists for this profile (secret stored), regardless of whether
  /// this session already unlocked it. Read errors must block access.
  Future<bool> isLocked(String profileId) async {
    final raw = await _storage.read(key: _key(profileId));
    if (raw == null) return false;
    if (!RegExp(r'^[0-9a-f]{32}:[0-9a-f]{64}$').hasMatch(raw)) {
      throw const FormatException('Invalid profile lock');
    }
    return true;
  }

  bool isUnlocked(String profileId) => _unlocked.contains(profileId);

  void markUnlocked(String profileId) => _unlocked.add(profileId);

  void approveSwitch(String profileId) => _switchApprovals.add(profileId);
  bool consumeSwitchApproval(String profileId) =>
      _switchApprovals.remove(profileId);
  void clearSwitchApprovals() => _switchApprovals.clear();
  void lockEntry(String profileId) => _unlocked.remove(profileId);
  Future<bool> needsLegacyPin(String profileId) async => false;

  /// Set (or replace) the PIN. Minimum 4 characters — enforced here, not
  /// just in the UI, so every caller gets the same floor.
  Future<bool> setPin(
    String profileId,
    String pin, {
    String? currentPin,
  }) async {
    if (pin.length < 4) return false;
    final salt = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    final saltHex = _hex(salt);
    await _storage.write(
      key: _key(profileId),
      value: '$saltHex:${_hash(pin, salt)}',
    );
    _unlocked.add(profileId);
    return true;
  }

  /// Wrong PIN (or no lock) returns false — never throws, so the gate sheet
  /// just shows its error line instead of crashing on a corrupt entry.
  Future<bool> verify(String profileId, String pin, {String? localPin}) async {
    try {
      final raw = await _storage.read(key: _key(profileId));
      if (raw == null) return false;
      final sep = raw.indexOf(':');
      if (sep <= 0) return false;
      final salt = _unhex(raw.substring(0, sep));
      if (salt == null) return false;
      final ok = _constantTimeEqual(_hash(pin, salt), raw.substring(sep + 1));
      if (ok) _unlocked.add(profileId);
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> clear(String profileId, {String? pin}) async {
    _unlocked.remove(profileId);
    try {
      await _storage.delete(key: _key(profileId));
    } catch (_) {}
  }

  /// True when the device can do a biometric prompt right now. Anything
  /// throws on exotic platforms (tvOS) — those just don't get the shortcut.
  Future<bool> get canUseBiometrics async {
    try {
      return await _biometrics.canCheckBiometrics &&
          await _biometrics.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> canUnlockWithBiometrics(String profileId) => canUseBiometrics;

  Future<bool> biometricEnabled(String profileId) async => false;

  Future<void> setBiometricEnabled(
    String profileId,
    bool enabled, {
    String? pin,
  }) async {
    throw UnsupportedError('Synced profile locks are required');
  }

  Future<void> forgetDeletedProfile(String owner, String profileId) async {}

  String? takeRecoveryCode(String profileId) => null;

  Future<bool> recover(
    String profileId,
    String code,
    String newPin, {
    String? localPin,
  }) async => false;

  /// One biometric attempt. False covers fail, cancel, and unavailable —
  /// the caller always falls through to the PIN.
  Future<bool> authenticateBiometric(String reason, {String? profileId}) async {
    try {
      final ok = await _biometrics.authenticate(
        localizedReason: reason,
        biometricOnly: true,
      );
      return ok;
    } catch (_) {
      return false;
    }
  }

  static final _secureRandom = Random.secure();

  /// SHA-256(salt + utf8(pin)), hex. Salt first so identical PINs on two
  /// profiles hash differently.
  static String hashForTest(String pin, List<int> salt) => _hash(pin, salt);

  static String _hash(String pin, List<int> salt) =>
      sha256.convert([...salt, ...utf8.encode(pin)]).toString();

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int>? _unhex(String hex) {
    if (hex.length % 2 != 0) return null;
    try {
      return [
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Compare every character so a wrong PIN doesn't fail faster on an early
  /// byte — overkill for a 4-digit PIN, but the loop is three lines.
  static bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
