import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestClient, PostgrestException;

class ProfileLockException implements Exception {
  const ProfileLockException(this.code, {this.retryAfter});
  final String code;
  final int? retryAfter;

  String get message => switch (code) {
    'biometric_cancelled' =>
      'Fingerprint was not enabled. Try again or cancel.',
    'invalid_pin' => 'Choose a 4 or 6 digit PIN.',
    'verification_failed' => 'Incorrect PIN or recovery code.',
    'rate_limited' => 'Too many attempts. Please try again later.',
    'sign_in_required' => 'Sign in to use a synced profile lock.',
    'online_required' =>
      'Connect to the internet to check this profile’s lock.',
    'device_limit' =>
      'Too many fingerprint devices. Change the PIN to reset them.',
    'profile_not_found' => 'This profile is no longer available.',
    'profile_locked' =>
      'Unlock every locked profile before accessing a full backup.',
    'backup_other_account' =>
      'This device has profile data from another account. A full backup cannot verify that account’s locks.',
    _ => 'Could not check the profile lock. Please try again.',
  };
  @override
  String toString() => 'ProfileLockException($code)';
}

abstract interface class ProfileLockRemote {
  Future<Map<String, dynamic>> request(
    String action, {
    String? profileId,
    String? pin,
    String? newPin,
    String? secret,
  });
}

class PostgrestProfileLockRemote implements ProfileLockRemote {
  PostgrestProfileLockRemote(this._client, this._accessToken);
  final PostgrestClient _client;
  final String? Function() _accessToken;

  @override
  Future<Map<String, dynamic>> request(
    String action, {
    String? profileId,
    String? pin,
    String? newPin,
    String? secret,
  }) async {
    final token = _accessToken();
    if (token == null || token.isEmpty) {
      throw const ProfileLockException('sign_in_required');
    }
    final Object? result;
    try {
      result = await _client
          .setAuth(token)
          .rpc(
            'profile_lock',
            params: {
              'p_action': action,
              'p_profile_id': profileId,
              'p_pin': pin,
              'p_new_pin': newPin,
              'p_secret': secret,
            },
          )
          .timeout(const Duration(seconds: 15));
    } on PostgrestException catch (error) {
      if (error.code == 'PT403') {
        throw const ProfileLockException('profile_locked');
      }
      if (error.code == 'PGRST301' || error.code == 'PGRST303') {
        throw const ProfileLockException('sign_in_required');
      }
      throw const ProfileLockException('online_required');
    } catch (_) {
      // Never include RPC parameters or HTTP bodies in errors: they contain credentials.
      throw const ProfileLockException('online_required');
    }
    if (result is! Map) throw const ProfileLockException('invalid_response');
    final response = Map<String, dynamic>.from(result);
    if (response['ok'] != true) {
      throw ProfileLockException(
        response['error'] as String? ?? 'invalid_response',
        retryAfter: (response['retry_after'] as num?)?.toInt(),
      );
    }
    return response;
  }
}
