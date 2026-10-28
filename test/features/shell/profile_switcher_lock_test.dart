import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/profiles/profile_lock_store.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/shell/root_shell.dart';

class _Profiles extends ViewerProfileStore {
  String owner = 'account-a';
  @override
  String get ownerKey => owner;
  _Profiles() {
    active.value = profiles.first;
  }

  @override
  List<ViewerProfile> get profiles => const [
    ViewerProfile(id: kDefaultProfileId, name: 'Home'),
    ViewerProfile(id: 'locked', name: 'Locked'),
  ];

  @override
  Future<void> switchTo(String profileId) async {
    active.value = profiles.firstWhere((profile) => profile.id == profileId);
  }
}

class _Locks extends ProfileLockStore {
  bool locked = true;
  bool legacy = false;
  @override
  Future<bool> needsLegacyPin(String id) async => legacy;

  @override
  Future<bool> isLocked(String profileId) async =>
      locked && profileId == 'locked';

  @override
  Future<bool> get canUseBiometrics async => false;

  @override
  Future<bool> verify(String profileId, String pin, {String? localPin}) async {
    if (pin != '1234') return false;
    markUnlocked(profileId);
    return true;
  }
}

Future<void> _chooseLocked(
  WidgetTester tester, {
  String choiceKey = 'profile-switcher-choice-locked',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => openProfileSwitcher(context),
            child: const Text('Switch'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Switch'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(choiceKey)));
  await tester.pumpAndSettle();
}

void main() {
  late _Profiles profiles;
  late _Locks locks;

  setUp(() async {
    await sl.reset();
    profiles = _Profiles();
    locks = _Locks();
    sl.registerSingleton<ViewerProfileStore>(profiles);
    sl.registerSingleton<ProfileLockStore>(locks);
  });

  tearDown(() => sl.reset());

  testWidgets('old device PIN stays hidden until a failed unlock needs it', (
    tester,
  ) async {
    locks.legacy = true;
    await _chooseLocked(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).keyboardType,
      TextInputType.number,
    );
    await tester.enterText(find.byType(TextField), '0000');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock profile'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(profiles.activeId, kDefaultProfileId);
  });

  testWidgets('navbar requires the correct PIN before switching profiles', (
    tester,
  ) async {
    await _chooseLocked(tester);
    expect(profiles.activeId, kDefaultProfileId);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '0000');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock profile'));
    await tester.pumpAndSettle();
    expect(profiles.activeId, kDefaultProfileId);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock profile'));
    await tester.pumpAndSettle();
    expect(profiles.activeId, 'locked');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'account changes during PIN entry cannot switch the new account',
    (tester) async {
      await _chooseLocked(tester);
      profiles.owner = 'account-b';
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock profile'));
      await tester.pumpAndSettle();
      expect(profiles.activeId, kDefaultProfileId);
    },
  );

  testWidgets('cancelling navbar PIN entry keeps the current profile', (
    tester,
  ) async {
    await _chooseLocked(tester);
    expect(find.byType(TextField), findsOneWidget);
    Navigator.of(tester.element(find.byType(TextField))).pop();
    await tester.pumpAndSettle();
    expect(profiles.activeId, kDefaultProfileId);
  });

  testWidgets('navbar still opens an unlocked profile directly', (
    tester,
  ) async {
    locks.locked = false;
    await _chooseLocked(tester);
    expect(profiles.activeId, 'locked');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'navbar asks again when returning to a previously unlocked profile',
    (tester) async {
      locks.markUnlocked('locked');
      await _chooseLocked(tester);
      expect(profiles.activeId, kDefaultProfileId);
      expect(find.byType(TextField), findsOneWidget);
    },
  );

  testWidgets('the active authenticated profile does not ask again', (
    tester,
  ) async {
    await profiles.switchTo('locked');
    locks.markUnlocked('locked');
    await _chooseLocked(tester, choiceKey: 'profile-switcher-active');
    expect(profiles.activeId, 'locked');
    expect(find.byType(TextField), findsNothing);
  });
}
