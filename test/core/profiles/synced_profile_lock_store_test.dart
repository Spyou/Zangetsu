import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:watch_app/core/profiles/profile_lock_remote.dart';
import 'package:watch_app/core/profiles/synced_profile_lock_store.dart';
import 'package:watch_app/core/profiles/profile_lock_store.dart';

class _Storage extends FlutterSecureStorage {
  final values = <String, String>{};
  bool failWrites = false;
  void Function(String)? onRead;
  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(values);
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    onRead?.call(key);
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrites) throw StateError('storage unavailable');
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

class _Biometrics extends LocalAuthentication {
  bool accept = true;
  int prompts = 0;
  void Function()? onPrompt;
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    prompts++;
    onPrompt?.call();
    expect(biometricOnly, isTrue);
    return accept;
  }

  @override
  Future<bool> get canCheckBiometrics async => true;
  @override
  Future<bool> isDeviceSupported() async => true;
}

class _Remote implements ProfileLockRemote {
  bool locked = true;
  bool offline = false;
  String? failureCode;
  int version = 1;
  int enrollments = 0;
  final actions = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String action, {
    String? profileId,
    String? pin,
    String? newPin,
    String? secret,
  }) async {
    if (offline) throw Exception('Network unavailable');
    if (failureCode != null) throw ProfileLockException(failureCode!);
    actions.add(action);
    if ((action == 'set' || action == 'recover') &&
        !ProfileLockStore.isValidNewPin(newPin ?? '')) {
      throw const ProfileLockException('invalid_pin');
    }
    if (action == 'status' && profileId == null) {
      return {
        'ok': true,
        'profiles': [
          {'profile_id': 'private', 'locked': locked, 'version': version},
        ],
      };
    }
    if (action == 'status') {
      return {'ok': true, 'locked': locked, 'version': version};
    }
    if (action == 'unlock' && pin != '1234') {
      throw const ProfileLockException('verification_failed');
    }
    if (action == 'device_enroll') {
      if (pin != '1234') {
        throw const ProfileLockException('verification_failed');
      }
      enrollments++;
    }
    if (action == 'set') {
      locked = true;
      version++;
    }
    return {
      'ok': true,
      'locked': locked,
      'version': version,
      'grant_token': 'a' * 64,
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 12))
          .toIso8601String(),
      if (action == 'device_enroll') 'device_token': 'b' * 64,
      if (action == 'set') 'recovery_code': 'c' * 32,
    };
  }
}

void main() {
  late _Remote remote;
  late _Storage storage;
  late String? owner;
  SyncedProfileLockStore create() => SyncedProfileLockStore(
    remote: remote,
    currentUserId: () => owner,
    storage: storage,
    biometrics: _Biometrics(),
  );
  setUp(() {
    remote = _Remote();
    storage = _Storage();
    owner = 'account-a';
  });

  test('a verified PIN unlocks cached data offline after restart', () async {
    final locks = create();
    expect(await locks.verify('private', '1234'), isTrue);
    remote.offline = true;
    final restarted = create();
    expect(await restarted.isLocked('private'), isTrue);
    expect(await restarted.verify('private', '0000'), isFalse);
    expect(restarted.isUnlocked('private'), isFalse);
    expect(await restarted.verify('private', '1234'), isTrue);
    expect(restarted.isUnlocked('private'), isTrue);
    expect(restarted.grantHeaders, isEmpty);
  });

  test('offline PIN approval belongs to its account and profile', () async {
    await create().verify('private', '1234');
    remote.offline = true;
    owner = 'account-b';
    await expectLater(
      create().verify('private', '1234'),
      throwsA(isA<ProfileLockException>()),
    );
    owner = 'account-a';
    await expectLater(
      create().verify('another-profile', '1234'),
      throwsA(isA<ProfileLockException>()),
    );
  });

  test('seeing a newer PIN version invalidates its offline verifier', () async {
    final locks = create();
    await locks.verify('private', '1234');
    remote.version++;
    expect(await locks.isLocked('private'), isTrue);
    remote.offline = true;
    await expectLater(
      create().verify('private', '1234'),
      throwsA(isA<ProfileLockException>()),
    );
  });

  test('offline wrong-PIN attempts stay limited after restart', () async {
    await create().verify('private', '1234');
    remote.offline = true;
    for (var i = 0; i < 5; i++) {
      expect(await create().verify('private', '0000'), isFalse);
    }
    await expectLater(
      create().verify('private', '1234'),
      throwsA(
        isA<ProfileLockException>().having(
          (error) => error.code,
          'code',
          'rate_limited',
        ),
      ),
    );
  });

  test('a server denial never falls back to the saved offline PIN', () async {
    await create().verify('private', '1234');
    remote.failureCode = 'sign_in_required';
    await expectLater(
      create().verify('private', '1234'),
      throwsA(
        isA<ProfileLockException>().having(
          (error) => error.code,
          'code',
          'sign_in_required',
        ),
      ),
    );
  });

  test(
    'an offline unlock cannot cross an account switch during storage read',
    () async {
      await create().verify('private', '1234');
      remote.offline = true;
      final locks = create();
      storage.onRead = (key) {
        if (key == 'synced_profile_offline_pin_account-a_private') {
          owner = 'account-b';
        }
      };
      await expectLater(
        locks.verify('private', '1234'),
        throwsA(
          isA<ProfileLockException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      expect(locks.isUnlocked('private'), isFalse);
      expect(locks.grantHeaders, isEmpty);
    },
  );

  test(
    'offline PIN attempts cannot race around the local retry limit',
    () async {
      final locks = create();
      await locks.verify('private', '1234');
      remote.offline = true;
      final attempts = await Future.wait(
        List.generate(5, (_) => locks.verify('private', '0000')),
      );
      expect(attempts, everyElement(isFalse));
      await expectLater(
        locks.verify('private', '1234'),
        throwsA(
          isA<ProfileLockException>().having(
            (error) => error.code,
            'code',
            'rate_limited',
          ),
        ),
      );
    },
  );

  test(
    'enrolled biometrics can unlock local data offline but cannot grant cloud access',
    () async {
      await create().setBiometricEnabled('private', true, pin: '1234');
      remote.offline = true;
      final locks = create();
      expect(
        await locks.authenticateBiometric('Unlock', profileId: 'private'),
        isTrue,
      );
      expect(locks.isUnlocked('private'), isTrue);
      expect(locks.grantHeaders, isEmpty);
    },
  );

  test('deleting a profile removes its offline verifier', () async {
    final locks = create();
    await locks.verify('private', '1234');
    await locks.forgetDeletedProfile('account-a', 'private');
    expect(
      storage.values.keys,
      isNot(contains('synced_profile_offline_pin_account-a_private')),
    );
    remote.offline = true;
    await expectLater(
      create().verify('private', '1234'),
      throwsA(isA<ProfileLockException>()),
    );
  });

  test(
    'a newer lock observed during offline verification cancels the unlock',
    () async {
      final locks = create();
      await locks.verify('private', '1234');
      locks.lockEntry('private');
      remote.offline = true;
      Future<bool>? refresh;
      storage.onRead = (key) {
        if (key == 'synced_profile_offline_pin_account-a_private') {
          storage.onRead = null;
          remote.offline = false;
          remote.version++;
          refresh = locks.isLocked('private');
        }
      };
      await expectLater(
        locks.verify('private', '1234'),
        throwsA(
          isA<ProfileLockException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      await refresh;
      expect(locks.isUnlocked('private'), isFalse);
      remote.offline = true;
      await expectLater(
        create().verify('private', '1234'),
        throwsA(isA<ProfileLockException>()),
      );
    },
  );

  test(
    'signing out opens isolated guest data without the account PIN',
    () async {
      var isolated = false;
      final locks = SyncedProfileLockStore(
        remote: remote,
        currentUserId: () => owner,
        storage: storage,
        isolateGuestData: () async {
          isolated = true;
        },
      );
      await locks.verify('default', '1234');
      owner = null;
      remote.offline = true;
      expect(await locks.isLocked('default'), isFalse);
      expect(isolated, isTrue);
      expect(locks.isUnlocked('default'), isFalse);
      expect(locks.grantHeaders, isEmpty);
      expect(
        storage.values.containsKey('synced_profile_status_account-a_default'),
        isTrue,
      );
    },
  );

  test('a guest cannot bypass lock isolation when storage fails', () async {
    final locks = SyncedProfileLockStore(
      remote: remote,
      currentUserId: () => owner,
      storage: storage,
      isolateGuestData: () async {
        throw StateError('storage unavailable');
      },
    );
    await locks.verify('default', '1234');
    owner = null;
    await expectLater(locks.isLocked('default'), throwsA(isA<StateError>()));
  });

  test('changing the PIN replaces the offline verifier', () async {
    final locks = create();
    await locks.verify('private', '1234');
    expect(await locks.setPin('private', '567890', currentPin: '1234'), isTrue);
    remote.offline = true;
    final restarted = create();
    expect(await restarted.verify('private', '1234'), isFalse);
    expect(await restarted.verify('private', '567890'), isTrue);
    expect(restarted.grantHeaders, isEmpty);
  });

  test('removing the PIN deletes its saved offline verifier', () async {
    final locks = create();
    await locks.verify('private', '1234');
    await locks.clear('private', pin: '1234');
    expect(
      storage.values.keys,
      isNot(contains('synced_profile_offline_pin_account-a_private')),
    );
  });

  test('corrupt offline PIN storage denies access', () async {
    await create().verify('private', '1234');
    storage.values['synced_profile_offline_pin_account-a_private'] = 'invalid';
    remote.offline = true;
    final locks = create();
    await expectLater(
      locks.verify('private', '1234'),
      throwsA(isA<FormatException>()),
    );
    expect(locks.isUnlocked('private'), isFalse);
    expect(locks.grantHeaders, isEmpty);
  });

  test(
    'a correct online PIN repairs corrupt offline verification data',
    () async {
      await create().verify('private', '1234');
      storage.values['synced_profile_offline_pin_account-a_private'] =
          'invalid';
      expect(await create().verify('private', '1234'), isTrue);
      remote.offline = true;
      expect(await create().verify('private', '1234'), isTrue);
    },
  );

  test(
    'signing out cannot export stale unlocked cloud profile data offline',
    () async {
      remote.locked = false;
      final locks = create();
      await locks.isLocked('private');
      owner = null;
      remote.offline = true;
      await expectLater(
        locks.requireBackupAccess(),
        throwsA(isA<ProfileLockException>()),
      );
    },
  );

  test(
    'switching accounts cannot export another account stale unlocked profile data',
    () async {
      remote.locked = false;
      final locks = create();
      await locks.isLocked('private');
      owner = 'account-b';
      await expectLater(
        locks.requireBackupAccess(),
        throwsA(isA<ProfileLockException>()),
      );
    },
  );

  test(
    'last known unlocked status works offline and refreshes on reconnect',
    () async {
      remote.locked = false;
      final locks = create();
      expect(await locks.isLocked('private'), isFalse);
      remote.locked = true;
      remote.offline = true;
      expect(await locks.isLocked('private'), isFalse);
      expect(await create().isLocked('private'), isFalse);
      remote.offline = false;
      expect(await create().isLocked('private'), isTrue);
    },
  );

  test('offline backup cannot trust a stale unlocked profile status', () async {
    remote.locked = false;
    final locks = SyncedProfileLockStore(
      remote: remote,
      currentUserId: () => owner,
      storage: storage,
    );
    await locks.requireBackupAccess();
    remote.locked = true;
    remote.offline = true;
    await expectLater(
      locks.requireBackupAccess(),
      throwsA(isA<ProfileLockException>()),
    );
  });

  test(
    'account switch during fingerprint unlock cannot use the next account token',
    () async {
      final bio = _Biometrics();
      final locks = SyncedProfileLockStore(
        remote: remote,
        currentUserId: () => owner,
        storage: storage,
        biometrics: bio,
      );
      await locks.setBiometricEnabled('private', true, pin: '1234');
      owner = 'account-b';
      await locks.setBiometricEnabled('private', true, pin: '1234');
      owner = 'account-a';
      bio.onPrompt = () {
        owner = 'account-b';
      };
      remote.actions.clear();
      await expectLater(
        locks.authenticateBiometric('Unlock', profileId: 'private'),
        throwsA(isA<ProfileLockException>()),
      );
      expect(remote.actions, isNot(contains('device_unlock')));
    },
  );

  test(
    'account switch while disabling cannot delete another account token',
    () async {
      final locks = create();
      await locks.setBiometricEnabled('private', true, pin: '1234');
      owner = 'account-b';
      await locks.setBiometricEnabled('private', true, pin: '1234');
      final token = storage.values['synced_profile_device_account-b_private'];
      owner = 'account-a';
      storage.onRead = (key) {
        if (key == 'synced_profile_device_account-a_private') {
          owner = 'account-b';
        }
      };
      await expectLater(
        locks.setBiometricEnabled('private', false),
        throwsA(isA<ProfileLockException>()),
      );
      expect(storage.values['synced_profile_device_account-b_private'], token);
    },
  );

  test(
    'changing account during the biometric prompt cannot enroll the new account',
    () async {
      final bio = _Biometrics()
        ..onPrompt = () {
          owner = 'account-b';
        };
      final locks = SyncedProfileLockStore(
        remote: remote,
        currentUserId: () => owner,
        storage: storage,
        biometrics: bio,
      );
      await expectLater(
        locks.setBiometricEnabled('private', true, pin: '1234'),
        throwsA(isA<ProfileLockException>()),
      );
      expect(remote.enrollments, 0);
      expect(
        storage.values.keys.where(
          (k) => k.startsWith('synced_profile_device_'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'fingerprint enrollment needs PIN and a successful device prompt',
    () async {
      final bio = _Biometrics()..accept = false;
      final locks = SyncedProfileLockStore(
        remote: remote,
        currentUserId: () => owner,
        storage: storage,
        biometrics: bio,
      );
      await expectLater(
        locks.setBiometricEnabled('private', true, pin: '0000'),
        throwsA(isA<ProfileLockException>()),
      );
      expect(bio.prompts, 0);
      await expectLater(
        locks.setBiometricEnabled('private', true, pin: '1234'),
        throwsA(isA<ProfileLockException>()),
      );
      expect(bio.prompts, 1);
      expect(remote.enrollments, 0);
      expect(await locks.biometricEnabled('private'), isFalse);
      bio.accept = true;
      await locks.setBiometricEnabled('private', true, pin: '1234');
      expect(remote.enrollments, 1);
      expect(await locks.biometricEnabled('private'), isTrue);
    },
  );

  test(
    'an older password can be replaced without losing its local lock',
    () async {
      remote.locked = false;
      await ProfileLockStore(
        storage: storage,
      ).setPin('private', 'old-password');
      final locks = create();
      await expectLater(
        locks.verify('private', 'old-password'),
        throwsA(isA<ProfileLockException>()),
      );
      expect(storage.values.containsKey('profile_lock_private'), isTrue);
      await expectLater(
        locks.setPin('private', '012345', currentPin: 'wrong'),
        throwsA(isA<ProfileLockException>()),
      );
      expect(
        await locks.setPin('private', '012345', currentPin: 'old-password'),
        isTrue,
      );
    },
  );

  test('new PINs allow exactly four or six ASCII digits', () async {
    remote.locked = false;
    final locks = create();
    for (final pin in ['123', '12345', '1234567', 'abcd', '12a4']) {
      expect(await locks.setPin('private', pin), isFalse);
    }
    expect(remote.actions, isEmpty);
    expect(await locks.setPin('private', '0123'), isTrue);
    expect(await locks.setPin('private', '012345', currentPin: '0123'), isTrue);
    await expectLater(
      locks.recover('private', 'code', '12345'),
      throwsA(isA<ProfileLockException>()),
    );
  });

  test(
    'backup cannot reuse unlocked cache after a failed locked-status write',
    () async {
      remote.locked = false;
      final locks = SyncedProfileLockStore(
        remote: remote,
        currentUserId: () => owner,
        storage: storage,
      );
      await locks.requireBackupAccess();
      remote.locked = true;
      storage.failWrites = true;
      await expectLater(
        locks.requireBackupAccess(),
        throwsA(isA<StateError>()),
      );
      storage.failWrites = false;
      remote.offline = true;
      await expectLater(
        locks.requireBackupAccess(),
        throwsA(isA<ProfileLockException>()),
      );
    },
  );

  test(
    'deleted profile metadata does not block another account backup',
    () async {
      final locks = create();
      await locks.isLocked('private');
      await locks.forgetDeletedProfile('account-a', 'private');
      owner = 'account-b';
      remote.locked = false;
      await locks.requireBackupAccess();
      expect(
        storage.values.keys,
        isNot(contains('synced_profile_status_account-a_private')),
      );
    },
  );

  test('existing local and server PINs both need verification', () async {
    await ProfileLockStore(storage: storage).setPin('private', '1111');
    final locks = create();
    expect(await locks.verify('private', '1234'), isFalse);
    expect(await locks.verify('private', '1234', localPin: '1111'), isTrue);
    expect(storage.values.containsKey('profile_lock_private'), isFalse);
  });

  test('failed status write cannot reuse an earlier unlocked cache', () async {
    remote.locked = false;
    final locks = create();
    expect(await locks.isLocked('private'), isFalse);
    remote.locked = true;
    storage.failWrites = true;
    await expectLater(locks.isLocked('private'), throwsA(isA<StateError>()));
    storage.failWrites = false;
    remote.offline = true;
    await expectLater(
      locks.isLocked('private'),
      throwsA(isA<ProfileLockException>()),
    );
  });

  test('recovery cannot erase an unverified legacy PIN', () async {
    await ProfileLockStore(storage: storage).setPin('private', '1111');
    final locks = create();
    await expectLater(
      locks.recover('private', 'recovery', '5678'),
      throwsA(isA<ProfileLockException>()),
    );
    expect(remote.actions, isNot(contains('recover')));
    expect(storage.values.containsKey('profile_lock_private'), isTrue);
  });

  test(
    'local PIN migration requires the original PIN before server enrollment',
    () async {
      remote.locked = false;
      final legacy = ProfileLockStore(storage: storage);
      await legacy.setPin('private', '1234');
      final locks = create();
      expect(await locks.isLocked('private'), isTrue);
      expect(await locks.verify('private', '0000'), isFalse);
      expect(remote.actions, isNot(contains('set')));
      expect(await locks.verify('private', '1234'), isTrue);
      expect(remote.actions, contains('set'));
      expect(locks.takeRecoveryCode('private'), 'c' * 32);
      expect(storage.values.containsKey('profile_lock_private'), isFalse);
    },
  );

  test(
    'signing out cannot expose cached locked default-profile data',
    () async {
      final locks = create();
      await locks.isLocked('default');
      owner = null;
      await expectLater(
        locks.isLocked('default'),
        throwsA(isA<ProfileLockException>()),
      );
    },
  );

  test(
    'a guest device without locked account data still works offline',
    () async {
      owner = null;
      remote.offline = true;
      expect(await create().isLocked('default'), isFalse);
      expect(remote.actions, isEmpty);
    },
  );

  test(
    'backup cannot export locked cached data belonging to another account',
    () async {
      final locks = create();
      await locks.isLocked('private');
      owner = 'account-b';
      await expectLater(
        locks.requireBackupAccess(),
        throwsA(isA<ProfileLockException>()),
      );
    },
  );

  test('server verification grants access only with the correct PIN', () async {
    final locks = create();
    expect(await locks.isLocked('private'), isTrue);
    expect(await locks.verify('private', '0000'), isFalse);
    expect(locks.isUnlocked('private'), isFalse);
    expect(await locks.verify('private', '1234'), isTrue);
    expect(locks.isUnlocked('private'), isTrue);
    expect(locks.grantHeaders['private'], 'a' * 64);
    expect(
      storage.values.values.any((value) => value.contains('1234')),
      isFalse,
    );
  });

  test('offline unlock grants local access without a cloud grant', () async {
    final locks = create();
    await locks.verify('private', '1234');
    locks.lockEntry('private');
    remote.offline = true;
    expect(await locks.isLocked('private'), isTrue);
    expect(await locks.verify('private', '1234'), isTrue);
    expect(locks.isUnlocked('private'), isTrue);
    expect(locks.grantHeaders, isEmpty);
  });

  test('only previously checked signed-in profiles can open offline', () async {
    remote.locked = false;
    await create().isLocked('public');
    remote.offline = true;
    expect(await create().isLocked('public'), isFalse);
    await expectLater(
      create().isLocked('unknown'),
      throwsA(isA<ProfileLockException>()),
    );
  });

  test(
    'fingerprint is off on another device and needs PIN enrollment',
    () async {
      final locks = create();
      expect(await locks.canUnlockWithBiometrics('private'), isFalse);
      await expectLater(
        locks.setBiometricEnabled('private', true, pin: '0000'),
        throwsA(isA<ProfileLockException>()),
      );
      expect(await locks.canUnlockWithBiometrics('private'), isFalse);
      await locks.setBiometricEnabled('private', true, pin: '1234');
      expect(await locks.canUnlockWithBiometrics('private'), isTrue);
      final otherDevice = SyncedProfileLockStore(
        remote: remote,
        currentUserId: () => owner,
        storage: _Storage(),
        biometrics: _Biometrics(),
      );
      expect(await otherDevice.canUnlockWithBiometrics('private'), isFalse);
    },
  );

  test(
    'account changes clear unlocks and do not reuse fingerprint approval',
    () async {
      final locks = create();
      await locks.verify('private', '1234');
      await locks.setBiometricEnabled('private', true, pin: '1234');
      owner = 'account-b';
      expect(locks.isUnlocked('private'), isFalse);
      expect(locks.grantHeaders, isEmpty);
      expect(await locks.canUnlockWithBiometrics('private'), isFalse);
    },
  );

  test(
    'PIN version changes invalidate the old grant and device approval',
    () async {
      final locks = create();
      await locks.verify('private', '1234');
      await locks.setBiometricEnabled('private', true, pin: '1234');
      remote.version++;
      await locks.isLocked('private');
      expect(locks.isUnlocked('private'), isFalse);
      expect(await locks.canUnlockWithBiometrics('private'), isFalse);
    },
  );
}
