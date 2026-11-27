import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/companion/companion_settings_screen.dart';
import 'package:watch_app/features/profiles/viewer_profile_home_screen.dart';

void main() {
  late Directory directory;
  late _TestViewerProfileStore profiles;
  late _TestAuthCubit auth;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_home');
    Hive.init(directory.path);
    await ViewerProfileStore.init();
    profiles = _TestViewerProfileStore();
    await profiles.loadForUser();
    auth = _TestAuthCubit();
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<ViewerProfileStore>(profiles)
      ..registerSingleton<AuthCubit>(auth);
  });

  tearDown(() async {
    await auth.close();
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('shows the active profile and actions', (tester) async {
    await tester.pumpWidget(_app(auth));

    final bioPlaceholder = tester.widget<Text>(find.text('Add a bio'));
    expect(bioPlaceholder.style?.fontSize, 14);
    expect(bioPlaceholder.style?.color, AppColors.textTertiary);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('About'), findsNothing);
    expect(find.text('Activity'), findsNothing);
    expect(find.text('Comments'), findsNothing);
    expect(find.text('Leaderboard'), findsNothing);
    expect(find.text('Profiles'), findsNothing);
    expect(find.text('More profile features'), findsNothing);
    expect(find.text('BLEACH'), findsNothing);
    expect(
      find.byKey(const ValueKey('zoro-coming-soon-section')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('zoro-coming-soon-gif')), findsNothing);
    final remote = find.byKey(const ValueKey('profile-remote-entry'));
    expect(remote, findsOneWidget);
    expect(
      find.descendant(of: remote, matching: find.text('Remote')),
      findsOneWidget,
    );
    // The tile shows no subtitle; the hint lives in Semantics only.
    expect(find.text('Control your TV with this phone'), findsNothing);
    expect(
      find.descendant(
        of: remote,
        matching: find.byIcon(Icons.settings_remote_rounded),
      ),
      findsOneWidget,
    );
    // The Remote entry is the first function under the stats divider.
    expect(
      tester.getTopLeft(remote).dy,
      greaterThan(tester.getTopLeft(find.text('Completed')).dy),
    );
    expect(find.byTooltip('Edit profile'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });

  testWidgets('profile avatar and content sit slightly higher together', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(auth));

    expect(
      tester
          .getTopLeft(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics &&
                  widget.properties.label == 'Home avatar',
            ),
          )
          .dy,
      lessThan(125),
    );
    final profileName = tester.widget<Text>(find.text('Home').last);
    expect(profileName.style?.fontSize, 22);
    expect(tester.getTopLeft(find.text('Home').last).dy, lessThan(223));
  });

  testWidgets('settings is one direct icon, not a menu', (tester) async {
    await tester.pumpWidget(_app(auth));
    expect(find.byTooltip('Profile menu'), findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.text('Pair a TV'), findsNothing);
  });

  testWidgets('fits a narrow phone without overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(auth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the active viewer bio without a duplicate profiles row', (
    tester,
  ) async {
    final guest = await tester.runAsync(() => profiles.create('Guest'));
    await profiles.switchTo(guest!.id);
    await tester.runAsync(
      () => profiles.update(guest.id, bio: 'Reading tonight'),
    );
    await tester.pumpWidget(_app(auth));
    expect(find.text('Reading tonight'), findsOneWidget);
    final bio = tester.widget<Text>(find.text('Reading tonight'));
    expect(bio.style?.fontSize, 14);
    expect(bio.style?.color, AppColors.textSecondary);
    expect(find.text('Profiles'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('profile selector opens the existing profile chooser', (
    tester,
  ) async {
    await tester.pumpWidget(_app(auth));
    await tester.tap(find.byKey(const ValueKey('profile-home-switch')));
    await tester.pumpAndSettle();

    expect(find.text("Who's watching?"), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Remote entry opens the phone remote with a back button', (
    tester,
  ) async {
    await tester.pumpWidget(_app(auth));
    await tester.ensureVisible(
      find.byKey(const ValueKey('profile-remote-entry')),
    );
    await tester.tap(find.byKey(const ValueKey('profile-remote-entry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final screen = tester.widget<CompanionSettingsScreen>(
      find.byType(CompanionSettingsScreen),
    );
    expect(screen.showBack, isTrue);
    expect(screen.active, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('feature grid', () {
    Future<void> pumpAt(
      WidgetTester tester,
      Size size, {
      double textScale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: _app(auth),
        ),
      );
    }

    final remote = find.byKey(const ValueKey('profile-remote-entry'));
    final tiles = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.container &&
          widget.properties.button == true,
    );

    // The page is capped at 760 wide with 20px side padding and 12px gaps.
    int columnsFor(WidgetTester tester, double screenWidth) {
      final content = (screenWidth < 760 ? screenWidth : 760) - 40;
      final tile = tester.getSize(remote).width;
      return ((content + 12) / (tile + 12)).round();
    }

    testWidgets('Remote is the first tile, inside a non-scrolling grid', (
      tester,
    ) async {
      await pumpAt(tester, const Size(390, 844));

      final grid = find.ancestor(of: remote, matching: find.byType(Wrap));
      expect(grid, findsOneWidget);
      final first = find.descendant(of: grid, matching: tiles).first;
      expect(find.descendant(of: first, matching: remote), findsOneWidget);
      // No nested scrolling: the only scrollable is the page itself.
      expect(
        find.ancestor(of: remote, matching: find.byType(Scrollable)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: remote,
          matching: find.byIcon(Icons.settings_remote_rounded),
        ),
        findsOneWidget,
      );
      final icon = tester.widget<Icon>(
        find.byIcon(Icons.settings_remote_rounded),
      );
      expect(icon.color, AppColors.accent);
      // Square at normal text size.
      final size = tester.getSize(remote);
      expect(size.height, closeTo(size.width, 1));
      expect(
        find.byKey(const ValueKey('zoro-coming-soon-section')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('zoro-coming-soon-gif')), findsNothing);
      expect(
        find.textContaining(RegExp('coming soon', caseSensitive: false)),
        findsNothing,
      );
    });

    testWidgets('Remote tile exposes a button label and hint', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAt(tester, const Size(390, 844));

      expect(
        tester.getSemantics(remote),
        isSemantics(
          label: 'Remote',
          hint: 'Control your TV with this phone',
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('3 columns on a 390 wide phone', (tester) async {
      await pumpAt(tester, const Size(390, 844));
      expect(columnsFor(tester, 390), 3);
      expect(tester.getSize(remote).width, 108);
    });

    testWidgets('4 columns on a 700 wide tablet', (tester) async {
      await pumpAt(tester, const Size(700, 1000));
      expect(columnsFor(tester, 700), 4);
      expect(tester.getSize(remote).width, 156);
    });

    testWidgets('no overflow at 320x640 with text scale 2.0', (tester) async {
      await pumpAt(tester, const Size(320, 640), textScale: 2);
      await tester.ensureVisible(remote);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(columnsFor(tester, 320), 3);
      final size = tester.getSize(remote);
      expect(size.height, greaterThanOrEqualTo(size.width));
    });

    testWidgets('no overflow at 1280x720', (tester) async {
      await pumpAt(tester, const Size(1280, 720));
      await tester.ensureVisible(remote);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(remote, findsOneWidget);
    });

    testWidgets('tile takes keyboard focus and Enter opens the remote', (
      tester,
    ) async {
      await pumpAt(tester, const Size(390, 844));
      await tester.ensureVisible(remote);
      await tester.pumpAndSettle();

      final focus = Focus.of(
        tester.element(
          find.descendant(of: remote, matching: find.byType(Column)).first,
        ),
      );
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CompanionSettingsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('signed-out profile asks the user to log in', (tester) async {
    await tester.pumpWidget(_app(auth));
    expect(find.text('Home'), findsWidgets);

    auth.signOut();
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Home'), findsNothing);
    expect(find.byTooltip('Edit profile'), findsNothing);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
  });
}

Widget _app(_TestAuthCubit auth) => BlocProvider<AuthCubit>.value(
  value: auth,
  child: const MaterialApp(home: ViewerProfileHomeScreen()),
);

class _TestViewerProfileStore extends ViewerProfileStore {
  @override
  Future<void> switchTo(String profileId) async {
    active.value = profiles.firstWhere((profile) => profile.id == profileId);
    revision.value++;
  }
}

class _TestAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _TestAuthCubit()
    : super(
        const AuthState(
          status: AuthStatus.authenticated,
          user: AuthUser(
            id: 'user-1',
            name: 'Test user',
            email: 'test@example.com',
          ),
        ),
      );

  void signOut() => emit(const AuthState(status: AuthStatus.unauthenticated));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
