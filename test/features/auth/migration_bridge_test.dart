// test/features/auth/migration_bridge_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';

void main() {
  test('password migration: ok response then successful sign-in -> true', () async {
    final b = MigrationBridge(
      invoke: (name, body) async => {'ok': true},
      signInPassword: (e, p) async => true,
      verifyOtp: (e, t) async => true,
    );
    expect(await b.tryPasswordMigration('k@x.com', 'pw'), isTrue);
  });
  test('password migration: verify_failed -> false, no sign-in', () async {
    var signedIn = false;
    final b = MigrationBridge(
      invoke: (name, body) async => {'ok': false, 'error': 'verify_failed'},
      signInPassword: (e, p) async { signedIn = true; return true; },
      verifyOtp: (e, t) async => true,
    );
    expect(await b.tryPasswordMigration('k@x.com', 'pw'), isFalse);
    expect(signedIn, isFalse);
  });
  test('session migration (case 2): ok + session -> verifyOtp -> true', () async {
    final b = MigrationBridge(
      invoke: (name, body) async => {'ok': true, 'session': {'email': 'k@x.com', 'token': 'otp123'}},
      signInPassword: (e, p) async => false,
      verifyOtp: (e, t) async => true,
    );
    expect(await b.trySessionMigration('jwt'), isTrue);
  });
  test('session migration: null jwt -> false', () async {
    final b = MigrationBridge(
      invoke: (n, b2) async => {'ok': true},
      signInPassword: (e, p) async => true, verifyOtp: (e, t) async => true);
    expect(await b.trySessionMigration(null), isFalse);
  });
}
