import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/profiles/profile_lock_store.dart';
import 'package:watch_app/core/profiles/profile_lock_remote.dart';
import 'package:watch_app/core/profiles/profile_shell_scope.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/profiles/profile_launch_gate.dart';
import 'package:watch_app/features/profiles/profile_lock_gate.dart';

class _Profiles extends ViewerProfileStore {
  String owner = 'account-a';
  @override
  String get ownerKey => owner;
  _Profiles() {
    active.value = const ViewerProfile(id: 'locked', name: 'Locked');
  }

  @override
  bool get askOnLaunch => false;
}

class _Locks extends ProfileLockStore {
  Future<bool> lookup = Future.value(false);
  int writes = 0;
  int checks = 0;
  bool bioAvailable = false;
  bool bioEnabled = false;
  int enrollments = 0;

  @override
  Future<bool> isLocked(String id) {
    checks++;
    return lookup;
  }

  @override
  Future<bool> get canUseBiometrics async => bioAvailable;

  @override
  Future<bool> biometricEnabled(String id) async => bioEnabled;

  @override
  Future<void> setBiometricEnabled(
    String id,
    bool enabled, {
    String? pin,
  }) async {
    if (enabled && pin != '1234') {
      throw const ProfileLockException('verification_failed');
    }
    enrollments++;
    bioEnabled = enabled;
  }

  @override
  Future<bool> verify(String id, String pin, {String? localPin}) async =>
      pin == '1234';

  @override
  Future<bool> setPin(String id, String pin, {String? currentPin}) async {
    if (await lookup && currentPin != '1234') {
      throw const ProfileLockException('verification_failed');
    }
    writes++;
    return true;
  }
}

Widget _launchApp() => MaterialApp(
  home: ProfileLaunchGate(
    child: Builder(
      builder: (context) => Text(
        ProfileShellScope.shouldDeferContent(context)
            ? 'Blocked'
            : 'Private content',
      ),
    ),
  ),
);

Future<void> _openSetup(
  WidgetTester tester,
  _Locks locks, {
  bool edit = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => manageProfilePin(
              context,
              profileId: 'locked',
              profileName: 'Locked',
              locks: locks,
            ),
            child: const Text('Edit PIN'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Edit PIN'));
  await tester.pumpAndSettle();
  if (edit &&
      find.byKey(const ValueKey('profile-change-pin')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('profile-change-pin')));
    await tester.pumpAndSettle();
  }
}

void main() {
  late _Locks locks;
  setUp(() async {
    await sl.reset();
    locks = _Locks();
    sl.registerSingleton<ViewerProfileStore>(_Profiles());
    sl.registerSingleton<ProfileLockStore>(locks);
  });
  tearDown(() => sl.reset());

  testWidgets(
    'PIN setup uses a numeric keypad and accepts four or six digits',
    (tester) async {
      locks.lookup = Future.value(false);
      await _openSetup(tester, locks);
      final fields = find.byType(TextField);
      expect(
        tester.widget<TextField>(fields.first).keyboardType,
        TextInputType.number,
      );
      await tester.enterText(fields.first, '12345');
      await tester.enterText(fields.last, '12345');
      await tester.tap(find.widgetWithText(FilledButton, 'Set profile PIN'));
      await tester.pumpAndSettle();
      expect(locks.writes, 0);
      expect(find.text('Choose a 4 or 6 digit PIN.'), findsOneWidget);
      await tester.enterText(fields.first, 'a012345b');
      await tester.enterText(fields.last, '012345');
      expect(tester.widget<TextField>(fields.first).controller!.text, '012345');
      await tester.tap(find.widgetWithText(FilledButton, 'Set profile PIN'));
      await tester.pumpAndSettle();
      expect(locks.writes, 1);
    },
  );

  testWidgets(
    'unapproved in-session profile switch blocks content immediately',
    (tester) async {
      locks.lookup = Future.value(false);
      await tester.pumpWidget(_launchApp());
      await tester.pumpAndSettle();
      expect(find.text('Private content'), findsOneWidget);
      final pending = Completer<bool>();
      locks.lookup = pending.future;
      sl<ViewerProfileStore>().active.value = const ViewerProfile(
        id: 'default',
        name: 'Home',
      );
      await tester.pump();
      expect(find.text('Private content'), findsNothing);
      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets('account change rechecks the same active profile id', (
    tester,
  ) async {
    locks.lookup = Future.value(false);
    await tester.pumpWidget(_launchApp());
    await tester.pumpAndSettle();
    final profiles = sl<ViewerProfileStore>() as _Profiles;
    final pending = Completer<bool>();
    locks.lookup = pending.future;
    profiles.owner = 'account-b';
    profiles.active.value = const ViewerProfile(
      id: 'locked',
      name: 'Other account',
    );
    await tester.pump();
    expect(find.text('Private content'), findsNothing);
    pending.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
    'metadata edits and already-approved switches do not reopen the gate',
    (tester) async {
      locks.lookup = Future.value(false);
      await tester.pumpWidget(_launchApp());
      await tester.pumpAndSettle();
      final checks = locks.checks;
      final profiles = sl<ViewerProfileStore>();
      profiles.active.value = const ViewerProfile(
        id: 'locked',
        name: 'Renamed',
      );
      await tester.pumpAndSettle();
      expect(locks.checks, checks);
      locks.approveSwitch('next');
      profiles.active.value = const ViewerProfile(id: 'next', name: 'Next');
      await tester.pumpAndSettle();
      expect(find.text('Private content'), findsOneWidget);
      expect(locks.checks, checks);
      expect(locks.consumeSwitchApproval('next'), isFalse);
    },
  );

  testWidgets('fingerprint setup is separate from changing PIN', (
    tester,
  ) async {
    locks.lookup = Future.value(true);
    locks.bioAvailable = true;
    await _openSetup(tester, locks, edit: false);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(locks.enrollments, 0);
    await tester.enterText(find.byType(TextField), '0000');
    await tester.tap(find.widgetWithText(FilledButton, 'Enable fingerprint'));
    await tester.pumpAndSettle();
    expect(locks.bioEnabled, isFalse);
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Enable fingerprint'));
    await tester.pumpAndSettle();
    expect(locks.bioEnabled, isTrue);
    expect(locks.writes, 0);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(locks.bioEnabled, isFalse);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('cancelling fingerprint setup keeps it off', (tester) async {
    locks.lookup = Future.value(true);
    locks.bioAvailable = true;
    await _openSetup(tester, locks, edit: false);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(TextField))).pop(false);
    await tester.pumpAndSettle();
    expect(locks.bioEnabled, isFalse);
    expect(locks.enrollments, 0);
  });

  testWidgets('startup hides content until the lock check completes', (
    tester,
  ) async {
    final pending = Completer<bool>();
    locks.lookup = pending.future;
    await tester.pumpWidget(_launchApp());
    expect(find.text('Private content'), findsNothing);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Private content'), findsOneWidget);
  });

  testWidgets('startup storage failure blocks content and supports retry', (
    tester,
  ) async {
    final pending = Completer<bool>();
    locks.lookup = pending.future;
    await tester.pumpWidget(_launchApp());
    pending.completeError(StateError('Storage unavailable'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Private content'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    locks.lookup = Future.value(false);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Private content'), findsOneWidget);
  });

  testWidgets('switch gate denies access when storage cannot be read', (
    tester,
  ) async {
    final pending = Completer<bool>();
    locks.lookup = pending.future;
    bool? allowed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                allowed = await ensureProfileUnlocked(
                  context,
                  sl<ViewerProfileStore>().activeProfile,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    pending.completeError(StateError('Storage unavailable'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(allowed, isFalse);
  });

  testWidgets('PIN setup cannot save while existing lock lookup is pending', (
    tester,
  ) async {
    final pending = Completer<bool>();
    locks.lookup = pending.future;
    await _openSetup(tester, locks);
    expect(find.byType(TextField), findsNothing);
    expect(locks.writes, 0);
    pending.complete(true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-change-pin')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(3));
    await tester.enterText(find.byType(TextField).at(0), '0000');
    await tester.enterText(find.byType(TextField).at(1), '4321');
    await tester.enterText(find.byType(TextField).at(2), '4321');
    await tester.tap(find.widgetWithText(FilledButton, 'Change PIN'));
    await tester.pumpAndSettle();
    expect(locks.writes, 0);
    await tester.enterText(find.byType(TextField).first, '1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Change PIN'));
    await tester.pumpAndSettle();
    expect(locks.writes, 1);
  });

  testWidgets(
    'PIN setup storage failure disables editing until retry succeeds',
    (tester) async {
      final pending = Completer<bool>();
      locks.lookup = pending.future;
      await _openSetup(tester, locks);
      pending.completeError(StateError('Storage unavailable'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      locks.lookup = Future.value(true);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('profile-change-pin')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(3));
      expect(locks.writes, 0);
    },
  );
}
