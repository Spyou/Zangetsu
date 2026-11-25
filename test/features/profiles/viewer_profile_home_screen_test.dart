import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
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
    final caption = find.text(
      'More features are on their way with Zoro… he just got lost again.',
    );
    expect(caption, findsOneWidget);
    expect(tester.widget<Text>(caption).textAlign, TextAlign.center);
    expect(find.text('More profile features'), findsNothing);
    expect(find.text('BLEACH'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CachedNetworkImage &&
            widget.imageUrl ==
                'https://custom-doodle.com/wp-content/uploads/doodle/auto-draft/one-piece-dancing-roronoa-zoro-doodle.gif' &&
            widget.fit == BoxFit.contain &&
            widget.width == 148 &&
            widget.height == 148,
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('zoro-coming-soon-gif')), findsOneWidget);
    expect(
      find.ancestor(
        of: caption,
        matching: find.byKey(const ValueKey('zoro-coming-soon-section')),
      ),
      findsOneWidget,
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
