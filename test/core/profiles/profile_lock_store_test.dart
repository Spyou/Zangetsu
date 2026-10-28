import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:watch_app/core/profiles/profile_lock_store.dart';

class _MemoryStorage extends FlutterSecureStorage {
  _MemoryStorage() : super();
  final map = <String, String>{};
  bool failRead = false;

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
    if (failRead) throw StateError('Secure storage unavailable');
    return map[key];
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
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
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
  }) async => map.remove(key);
}

class _NoBiometrics extends LocalAuthentication {
  @override
  Future<bool> get canCheckBiometrics async => false;

  @override
  Future<bool> isDeviceSupported() async => false;
}

void main() {
  test(
    'lock lookup does not treat storage errors as an unlocked profile',
    () async {
      final storage = _MemoryStorage()..failRead = true;
      final locks = ProfileLockStore(storage: storage);
      await expectLater(locks.isLocked('p1'), throwsStateError);
    },
  );

  test('malformed saved lock does not become an unlocked profile', () async {
    final storage = _MemoryStorage();
    storage.map['profile_lock_p1'] = 'corrupted';
    final locks = ProfileLockStore(storage: storage);
    await expectLater(locks.isLocked('p1'), throwsFormatException);
  });

  test('identical PINs on two profiles hash differently (salted)', () {
    final a = ProfileLockStore.hashForTest('1234', List.filled(16, 1));
    final b = ProfileLockStore.hashForTest('1234', List.filled(16, 2));
    expect(a, isNot(equals(b)));
    expect(ProfileLockStore.hashForTest('1234', List.filled(16, 1)), equals(a));
  });

  test('set, verify, wrong PIN, clear round-trip', () async {
    final storage = _MemoryStorage();
    final locks = ProfileLockStore(
      storage: storage,
      biometrics: _NoBiometrics(),
    );
    expect(await locks.isLocked('p1'), isFalse);
    expect(await locks.verify('p1', '1234'), isFalse);

    expect(await locks.setPin('p1', '123'), isFalse); // too short
    expect(await locks.isLocked('p1'), isFalse);
    expect(await locks.setPin('p1', '1234'), isTrue);
    expect(await locks.isLocked('p1'), isTrue);

    expect(await locks.verify('p1', '1234'), isTrue);
    expect(await locks.verify('p1', '0000'), isFalse);
    // A fresh store (new process) has no session unlock but keeps the lock.
    final fresh = ProfileLockStore(
      storage: storage,
      biometrics: _NoBiometrics(),
    );
    expect(fresh.isUnlocked('p1'), isFalse);
    expect(await fresh.isLocked('p1'), isTrue);

    await locks.clear('p1');
    expect(await locks.isLocked('p1'), isFalse);
  });

  test('biometrics unavailable degrades to PIN-only', () async {
    final locks = ProfileLockStore(
      storage: _MemoryStorage(),
      biometrics: _NoBiometrics(),
    );
    expect(await locks.canUseBiometrics, isFalse);
    expect(await locks.authenticateBiometric('reason'), isFalse);
  });
}
