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
  int removals = 0;
  int? knownPinLength;
  String currentPinValue = '1234';
  bool removedRemotely = false;

  @override
  Future<int?> pinLength(String profileId) async => knownPinLength;

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
  Future<bool> verify(String id, String pin, {String? localPin}) async {
    if (removedRemotely) throw const ProfileLockException('not_locked');
    return pin == currentPinValue;
  }

  @override
  Future<void> clear(String profileId, {String? pin}) async {
    if (pin != '1234') throw const ProfileLockException('verification_failed');
    removals++;
  }

  @override
  Future<bool> setPin(String id, String pin, {String? currentPin}) async {
    if (await lookup && currentPin != currentPinValue) {
      throw const ProfileLockException('verification_failed');
    }
    writes++;
    markUnlocked(id);
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

Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    await tester.tap(
      find.byKey(ValueKey('profile-pin-key-$digit')).hitTestable(),
    );
    await tester.pump();
  }
}

Future<void> _continue(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
  await tester.pumpAndSettle();
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

  for (final pin in ['0123', '012345']) {
    testWidgets('PIN setup accepts and confirms ${pin.length} digits', (
      tester,
    ) async {
      locks.lookup = Future.value(false);
      await _openSetup(tester, locks);
      expect(find.text('Use legacy PIN'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('${pin.length} digits'));
      await tester.pumpAndSettle();
      await _enterPin(tester, pin.substring(0, pin.length - 1));
      await _continue(tester);
      expect(locks.writes, 0);
      expect(find.text('Enter all ${pin.length} digits.'), findsOneWidget);
      await _enterPin(tester, pin.substring(pin.length - 1));
      await _continue(tester);
      await _enterPin(tester, '${pin.substring(0, pin.length - 1)}9');
      await tester.tap(find.widgetWithText(FilledButton, 'Set profile PIN'));
      await tester.pumpAndSettle();
      expect(locks.writes, 0);
      await tester.tap(find.byKey(const ValueKey('profile-pin-key-⌫')));
      await tester.pump();
      await _enterPin(tester, pin.substring(pin.length - 1));
      await tester.tap(find.widgetWithText(FilledButton, 'Set profile PIN'));
      await tester.pumpAndSettle();
      expect(locks.writes, 1);
    });
  }

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
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('profile-pin-key-1')), findsOneWidget);
    expect(locks.enrollments, 0);
    await _enterPin(tester, '0000');
    await tester.tap(find.widgetWithText(FilledButton, 'Enable fingerprint'));
    await tester.pumpAndSettle();
    expect(locks.bioEnabled, isFalse);
    await _enterPin(tester, '1234');
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
    Navigator.of(
      tester.element(find.byKey(const ValueKey('profile-pin-key-1'))),
    ).pop(false);
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

  testWidgets('remove PIN uses the keypad and requires the current PIN', (
    tester,
  ) async {
    locks.lookup = Future.value(true);
    await _openSetup(tester, locks, edit: false);
    await tester.tap(find.widgetWithText(TextButton, 'Remove lock'));
    await tester.pumpAndSettle();
    expect(find.text('Use legacy PIN'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('profile-pin-key-1')), findsOneWidget);
    await _enterPin(tester, '0000');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove lock'));
    await tester.pumpAndSettle();
    expect(locks.removals, 0);
    await _enterPin(tester, '1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove lock'));
    await tester.pumpAndSettle();
    expect(locks.removals, 1);
  });

  testWidgets('PIN setup fits a compact phone dialog', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 460));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    locks.lookup = Future.value(false);
    await _openSetup(tester, locks);
    await tester.tap(find.text('6 digits'));
    await tester.pumpAndSettle();
    final keypadKey = find.byKey(const ValueKey('profile-pin-key-1'));
    expect(tester.getSize(keypadKey), const Size(58, 58));
    final keyStyle = tester.widget<OutlinedButton>(keypadKey).style!;
    expect(keyStyle.shape!.resolve({}), isA<CircleBorder>());
    expect(keyStyle.backgroundColor!.resolve({}), Colors.transparent);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('Enter a new PIN'), findsOneWidget);
    expect(find.text('Set profile PIN'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'current four-digit PIN stays four when choosing a six-digit replacement',
    (tester) async {
      locks.lookup = Future.value(true);
      locks.knownPinLength = 4;
      await _openSetup(tester, locks);
      await tester.tap(find.text('6 digits'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-pin-dot-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-pin-dot-4')), findsNothing);
      await _enterPin(tester, '1234');
      await _continue(tester);
      expect(find.text('Enter a new PIN'), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-pin-dot-5')), findsOneWidget);
    },
  );

  for (final removed in [false, true]) {
    final change = removed ? 'removal' : 'length change';
    testWidgets('open PIN prompt handles remote lock $change', (tester) async {
      locks.lookup = Future.value(true);
      locks.knownPinLength = 4;
      var unlocked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  unlocked = await ensureProfileUnlocked(
                    context,
                    const ViewerProfile(id: 'locked', name: 'Locked'),
                    locks: locks,
                  );
                },
                child: const Text('Open profile'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open profile'));
      await tester.pumpAndSettle();

      locks.removedRemotely = removed;
      locks.currentPinValue = '123456';
      await _enterPin(tester, '1234');
      if (!removed) {
        expect(unlocked, isFalse);
        await _enterPin(tester, '123456');
        await tester.tap(find.widgetWithText(FilledButton, 'Unlock profile'));
      }
      await tester.pumpAndSettle();
      expect(unlocked, isTrue);
    });
  }

  testWidgets('an old PIN can migrate through Change PIN from unlock', (
    tester,
  ) async {
    locks.lookup = Future.value(true);
    locks.currentPinValue = 'old-pin';
    var unlocked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                unlocked = await ensureProfileUnlocked(
                  context,
                  const ViewerProfile(id: 'locked', name: 'Locked'),
                  locks: locks,
                );
              },
              child: const Text('Open profile'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    expect(find.text('Use legacy PIN'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Change PIN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 digits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use legacy PIN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'old-pin');
    await _continue(tester);
    await _enterPin(tester, '0123');
    await _continue(tester);
    await _enterPin(tester, '0123');
    await tester.tap(find.widgetWithText(FilledButton, 'Change PIN'));
    await tester.pumpAndSettle();
    expect(locks.writes, 1);
    expect(unlocked, isTrue);
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
    await tester.tap(find.text('4 digits'));
    await tester.pumpAndSettle();
    expect(find.text('Use legacy PIN'), findsOneWidget);
    await _continue(tester);
    expect(find.text('Enter your current PIN.'), findsOneWidget);
    expect(locks.writes, 0);
    await _enterPin(tester, '0000');
    await _continue(tester);
    await _enterPin(tester, '4321');
    await _continue(tester);
    await _enterPin(tester, '4321');
    await tester.tap(find.widgetWithText(FilledButton, 'Change PIN'));
    await tester.pumpAndSettle();
    expect(locks.writes, 0);
    await tester.tap(find.text('Edit current PIN'));
    await tester.pumpAndSettle();
    await _enterPin(tester, '1234');
    await _continue(tester);
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
      expect(find.text('4 digits'), findsOneWidget);
      expect(find.text('6 digits'), findsOneWidget);
      expect(locks.writes, 0);
    },
  );
}
