import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/profiles/viewer_profile_avatar.dart';
import 'package:watch_app/core/ui/image_fade.dart';
import 'package:watch_app/core/profiles/profile_shell_scope.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/tv/tv_list_focusable.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/profiles/profile_launch_gate.dart';
import 'package:watch_app/features/profiles/viewer_profiles_screen.dart';

void main() {
  late Directory directory;
  late ViewerProfileStore profiles;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_launch_gate');
    Hive.init(directory.path);
    await ViewerProfileStore.init();
    profiles = ViewerProfileStore();
    await profiles.loadForUser();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<ViewerProfileStore>(profiles);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Widget app() =>
      const MaterialApp(home: ProfileLaunchGate(child: Text('Main screen')));

  testWidgets('asks for a profile before showing the app', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.text('Main screen'), findsNothing);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Main screen'), findsOneWidget);
  });

  testWidgets('profile tap finishes the picker transition within 400ms', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text("Who's watching?"), findsNothing);
    expect(find.text('Main screen'), findsOneWidget);
  });

  testWidgets('defers shell content until a profile is selected', (
    tester,
  ) async {
    final deferredStates = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileLaunchGate(
          child: _ProfileGateShellProbe(onBuild: deferredStates.add),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(deferredStates.last, isTrue);
    expect(find.text('Main screen'), findsNothing);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(deferredStates.last, isFalse);
    expect(find.text('Main screen'), findsOneWidget);
  });

  testWidgets('launch picker uses round profile photos and actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.text('Ready for the next watch, Home?'), findsOneWidget);
    expect(
      find.textContaining('Kids profiles hide adult-rated titles'),
      findsNothing,
    );
    expect(find.text('Manage profiles'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(
      find.byKey(ValueKey('profile-avatar-fill-${profiles.profiles.first.id}')),
      findsOneWidget,
    );
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
  });

  testWidgets('phone picker uses large circular avatars', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    expect(
      tester.getSize(
        find.byKey(
          ValueKey('profile-avatar-fill-${profiles.profiles.first.id}'),
        ),
      ),
      const Size.square(120),
    );
    expect(
      tester.getTopLeft(find.text("Who's watching?")).dy,
      greaterThan(250),
    );
    expect(
      tester.getBottomLeft(find.text('Manage profiles')).dy,
      greaterThan(760),
    );
  });

  testWidgets('launch picker is full-bleed with a two-column phone grid', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      for (var i = 1; i < ViewerProfileStore.maxProfiles; i++) {
        await profiles.create('Profile $i');
      }
    });

    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    final background = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('profile-picker-background')),
    );
    final decoration = background.decoration as BoxDecoration;
    expect(decoration.gradient, isA<RadialGradient>());
    final backgroundGlow = decoration.gradient! as RadialGradient;
    expect(backgroundGlow.colors.last, AppColors.bg);
    expect(backgroundGlow.center, const Alignment(0, -0.7));
    expect(backgroundGlow.colors.first.a, greaterThan(0.2));
    expect(
      backgroundGlow.colors.first,
      AppColors.accent.withValues(alpha: 0.28),
    );
    expect(
      find.byKey(const ValueKey('profile-picker-backdrop-image')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('profile-picker-panel')), findsNothing);

    expect(find.byIcon(Icons.check_rounded), findsNothing);
    final profileAvatars = profiles.profiles
        .map(
          (profile) =>
              find.byKey(ValueKey('profile-avatar-fill-${profile.id}')),
        )
        .toList();
    expect(profileAvatars, hasLength(ViewerProfileStore.maxProfiles));
    for (final avatar in profileAvatars) {
      expect(tester.getSize(avatar), const Size.square(120));
    }

    final gridFinder = find.byKey(const ValueKey('profile-picker-grid'));
    final grid = tester.widget<GridView>(gridFinder);
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      2,
    );
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .mainAxisExtent,
      inInclusiveRange(160, 180),
    );
    expect(tester.getSize(gridFinder).width, inInclusiveRange(250, 270));
    expect(grid.childrenDelegate, isA<SliverChildListDelegate>());
    expect(
      (grid.childrenDelegate as SliverChildListDelegate).children.length,
      ViewerProfileStore.maxProfiles,
    );
  });

  testWidgets('picker uses loaded non-adult home artwork without fetching', (
    tester,
  ) async {
    const adultUrl = 'https://example.test/adult-banner.jpg';
    const safeUrl = 'https://image.tmdb.org/t/p/w780/safe-banner.jpg';
    GetIt.instance.registerSingleton<HomeCubit>(
      _SeededHomeCubit(
        HomeState(
          sections: [
            HomeSection(
              title: 'Trending',
              items: const [
                MediaItem(
                  id: 'adult',
                  title: 'Adult title',
                  banner: adultUrl,
                  url: '/adult',
                  type: ProviderType.anime,
                  sourceId: 'test',
                  isAdult: true,
                ),
                MediaItem(
                  id: 'safe',
                  title: 'Safe title',
                  banner: safeUrl,
                  url: '/safe',
                  type: ProviderType.anime,
                  sourceId: 'test',
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    final artwork = tester.widget<Image>(
      find.byKey(const ValueKey('profile-picker-backdrop-image')),
    );
    final resized = artwork.image as ResizeImage;
    expect(resized.imageProvider, isA<CachedNetworkImageProvider>());
    expect(
      (resized.imageProvider as CachedNetworkImageProvider).url,
      'https://image.tmdb.org/t/p/w1280/safe-banner.jpg',
    );
    expect(artwork.frameBuilder, same(imageFadeIn));
  });

  testWidgets('portrait picker uses poster artwork instead of a wide banner', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    GetIt.instance.registerSingleton<HomeCubit>(
      _SeededHomeCubit(
        HomeState(
          sections: [
            HomeSection(
              title: 'Trending',
              items: const [
                MediaItem(
                  id: 'safe',
                  title: 'Safe title',
                  cover: 'https://image.tmdb.org/t/p/w500/safe-poster.jpg',
                  banner: 'https://image.tmdb.org/t/p/w780/safe-banner.jpg',
                  url: '/safe',
                  type: ProviderType.anime,
                  sourceId: 'test',
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    final artwork = tester.widget<Image>(
      find.byKey(const ValueKey('profile-picker-backdrop-image')),
    );
    final resized = artwork.image as ResizeImage;
    expect(
      (resized.imageProvider as CachedNetworkImageProvider).url,
      'https://image.tmdb.org/t/p/w1280/safe-poster.jpg',
    );
  });

  testWidgets('avatar tap feedback uses circular picker shape', (tester) async {
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerProfilesScreen(
          selectionOnly: true,
          onSelected: () => selected = true,
        ),
      ),
    );

    final screenFade = find.byKey(
      const ValueKey('profile-picker-entry-screen-fade'),
    );
    final screenSlide = find.byKey(
      const ValueKey('profile-picker-entry-screen-slide'),
    );
    expect(tester.widget<FadeTransition>(screenFade).opacity.value, 0);
    expect(
      tester.widget<SlideTransition>(screenSlide).position.value.dy,
      closeTo(0.08, 0.01),
    );
    expect(tester.widget<SlideTransition>(screenSlide).child, isA<Scaffold>());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      tester.widget<FadeTransition>(screenFade).opacity.value,
      greaterThan(0),
    );
    expect(
      tester.widget<SlideTransition>(screenSlide).position.value.dy,
      lessThan(0.08),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<FadeTransition>(screenFade).opacity.value, 1);
    expect(
      tester.widget<SlideTransition>(screenSlide).position.value,
      Offset.zero,
    );

    final profile = profiles.profiles.first;
    final avatar = find.byKey(ValueKey('profile-avatar-${profile.id}'));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero && widget.tag == 'viewer-profile-${profile.id}',
      ),
      findsOneWidget,
    );
    final ripple = tester.widget<InkResponse>(
      find.byKey(ValueKey('profile-avatar-ink-${profile.id}')),
    );
    expect(ripple.containedInkWell, isTrue);
    expect(ripple.customBorder, isA<CircleBorder>());
    expect(ripple.highlightShape, BoxShape.circle);
    expect(ripple.splashColor, AppColors.textPrimary.withValues(alpha: 0.28));
    final fillFinder = find.byKey(
      ValueKey('profile-avatar-fill-${profile.id}'),
    );
    final fill = tester.widget<Material>(fillFinder);
    expect(fill.color, AppColors.accent);
    expect(fill.shape, isA<CircleBorder>());
    expect(tester.getSize(avatar), tester.getSize(fillFinder));
    expect(
      find.descendant(
        of: find.byKey(ValueKey('profile-avatar-fill-${profile.id}')),
        matching: find.byKey(ValueKey('profile-avatar-ink-${profile.id}')),
      ),
      findsOneWidget,
    );
    final scale = tester.widget<ScaleTransition>(avatar).scale;
    expect(
      find.ancestor(of: avatar, matching: find.byType(ScaleTransition)),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: avatar,
        matching: find.byKey(ValueKey('profile-entrance-${profile.id}')),
      ),
      findsOneWidget,
    );
    final gesture = await tester.startGesture(tester.getCenter(avatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(scale.value, closeTo(0.94, 0.01));

    await gesture.up();
    await tester.pump();
    expect(selected, isTrue);
    await tester.pump(const Duration(milliseconds: 90));
    expect(scale.value, greaterThan(1.04));
    await tester.pump(const Duration(milliseconds: 250));
    expect(scale.value, 1);
    await tester.pumpAndSettle();
    expect(selected, isTrue);
  });

  testWidgets('avatar returns to full size when a press is released outside', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerProfilesScreen(
          selectionOnly: true,
          onSelected: () => selected = true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    final profile = profiles.profiles.first;
    final avatar = find.byKey(ValueKey('profile-avatar-${profile.id}'));
    final scale = tester.widget<ScaleTransition>(avatar).scale;
    final gesture = await tester.startGesture(tester.getCenter(avatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(scale.value, closeTo(0.94, 0.01));

    await gesture.moveTo(Offset.zero);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(scale.value, 1);
    expect(selected, isFalse);
  });

  testWidgets('profile manager stays reachable when all profiles are used', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (var i = 1; i < ViewerProfileStore.maxProfiles; i++) {
        await profiles.create('Profile $i');
      }
    });

    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    expect(find.text('Manage profiles'), findsOneWidget);
    expect(find.text('Add'), findsNothing);
    await tester.tap(find.text('Manage profiles'));
    await tester.pumpAndSettle();

    expect(find.text('Profiles'), findsOneWidget);
    expect(find.byTooltip('Delete Profile 1'), findsOneWidget);
    expect(find.byTooltip('Delete Profile 2'), findsOneWidget);
    expect(find.byTooltip('Delete Profile 3'), findsOneWidget);
  });

  testWidgets('picker manage button opens the profile manager', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    await tester.tap(find.text('Manage profiles'));
    await tester.pumpAndSettle();

    expect(find.text('Profiles'), findsOneWidget);
    expect(find.text('Ask who is watching on launch'), findsOneWidget);
  });

  testWidgets('picker add tile opens the profile editor', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Add profile'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('TV picker exposes profile actions to D-pad focus', (
    tester,
  ) async {
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: true));

    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    expect(find.byType(TvListFocusable), findsNWidgets(3));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TvListFocusable &&
            widget.semanticLabel == 'Manage profiles',
      ),
      findsOneWidget,
    );
  });

  testWidgets('opens directly to the app when launch asking is disabled', (
    tester,
  ) async {
    await tester.runAsync(() => profiles.setAskOnLaunch(false));

    await tester.pumpWidget(app());

    expect(find.text('Main screen'), findsOneWidget);
    expect(find.text("Who's watching?"), findsNothing);
  });

  testWidgets('picker entrance staggers title, avatars, footer', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        await profiles.create('Profile $i');
      }
    });
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final titleFade = find.byKey(const ValueKey('profile-picker-title-fade'));
    expect(titleFade, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(titleFade).opacity.value,
      greaterThan(0),
    );
    final lastId = profiles.profiles.last.id;
    final lastAvatar = find.byKey(ValueKey('profile-entrance-$lastId'));
    expect(lastAvatar, findsOneWidget);
    expect(tester.widget<ScaleTransition>(lastAvatar).scale.value, 0.8);
    final footerFade = find.byKey(const ValueKey('profile-picker-footer-fade'));
    expect(footerFade, findsOneWidget);
    expect(tester.widget<FadeTransition>(footerFade).opacity.value, 0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<ScaleTransition>(lastAvatar).scale.value, 1.0);
    expect(tester.widget<FadeTransition>(footerFade).opacity.value, 1);
  });

  testWidgets('gate releases content before popping the picker', (
    tester,
  ) async {
    final deferredStates = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileLaunchGate(
          child: _ProfileGateShellProbe(onBuild: deferredStates.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(deferredStates.last, isTrue);
    final id = profiles.profiles.first.id;
    await tester.tap(find.byKey(ValueKey('profile-avatar-ink-$id')));
    await tester.pump(); // one frame: content released, pop not yet done
    expect(deferredStates.last, isFalse);
    expect(find.text("Who's watching?"), findsOneWidget);
  });

  testWidgets('launch selection flies a full-size avatar to the dock', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileLaunchGate(
          child: _ProfileGateHeroProbe(profiles: profiles),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('profile-avatar-ink-${profiles.profiles.first.id}')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final flight = find.byKey(const ValueKey('profile-flight-avatar'));
    expect(flight, findsOneWidget);
    expect(
      find.descendant(
        of: flight,
        matching: find.byKey(
          ValueKey('profile-avatar-fill-${profiles.profiles.first.id}'),
        ),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(flight, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(flight, findsNothing);
  });

  testWidgets('double selection fires once', (tester) async {
    var selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerProfilesScreen(
          selectionOnly: true,
          onSelected: () => selections++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final name = find.text(profiles.profiles.first.name).first;
    await tester.tap(name);
    await tester.pump();
    await tester.tap(name);
    await tester.pumpAndSettle();
    expect(selections, 1);
  });

  testWidgets('reduced motion shows everything instantly', (tester) async {
    await tester.runAsync(() async {
      await profiles.create('Second');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const ViewerProfilesScreen(selectionOnly: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final lastId = profiles.profiles.last.id;
    expect(find.byKey(ValueKey('profile-entrance-$lastId')), findsOneWidget);
    expect(
      tester
          .widget<ScaleTransition>(
            find.byKey(ValueKey('profile-entrance-$lastId')),
          )
          .scale
          .value,
      1.0,
    );
  });

  testWidgets('manager-screen tap pops without hero flight', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const ViewerProfilesScreen(),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(profiles.profiles.first.name).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('manager tile paints the profile avatar color', (tester) async {
    await tester.runAsync(() async {
      await profiles.create('Colored');
      await profiles.update(profiles.profiles.last.id, avatar: 3);
    });
    await tester.pumpWidget(const MaterialApp(home: ViewerProfilesScreen()));
    await tester.pumpAndSettle();
    final id = profiles.profiles.last.id;
    final avatar = find.byKey(ValueKey('profile-tile-avatar-$id'));
    expect(avatar, findsOneWidget);
    final box = tester.widget<Container>(avatar);
    expect(
      (box.decoration as BoxDecoration).color,
      viewerProfileAvatarColor(3),
    );
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: avatar, matching: find.byType(Icon)),
          )
          .icon,
      viewerProfileAvatarIcon(3),
    );
  });

  test('new profiles default to distinct avatars', () {
    expect(defaultAvatarForNewProfile(0), 0);
    expect(defaultAvatarForNewProfile(1), 1);
    expect(defaultAvatarForNewProfile(viewerProfileAvatarIcons.length), 0);
  });

  test('profile photo takes priority over the default account photo', () {
    final profile = ViewerProfile(
      id: kDefaultProfileId,
      name: 'Home',
      photoUrl: 'https://example.com/profile.png',
    );
    expect(
      profilePhotoForFace(
        profile: profile,
        accountPhotoUrl: 'https://example.com/pic.png',
      ),
      'https://example.com/profile.png',
    );
    expect(
      profilePhotoForFace(
        profile: ViewerProfile(id: kDefaultProfileId, name: 'Home'),
        accountPhotoUrl: 'https://example.com/pic.png',
      ),
      'https://example.com/pic.png',
    );
    expect(
      profilePhotoForFace(
        profile: ViewerProfile(id: 'custom', name: 'Custom'),
        accountPhotoUrl: null,
      ),
      isNull,
    );
  });

  testWidgets('default profile avatar shows the account photo', (tester) async {
    await tester.runAsync(() async {
      await profiles.create('Other');
      await profiles.update(profiles.profiles.last.id, avatar: 1);
    });
    GetIt.instance.registerSingleton<AuthCubit>(_PhotoAuthCubit());
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );
    await tester.pumpAndSettle();
    final defaultId = profiles.profiles.first.id;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('profile-avatar-fill-$defaultId')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    final otherId = profiles.profiles.last.id;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('profile-avatar-fill-$otherId')),
        matching: find.byIcon(viewerProfileAvatarIcon(1)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('picker crops the saved profile photo into a circle', (
    tester,
  ) async {
    const photoUrl = 'https://cdn.example/profile.jpg';
    ViewerProfile? customProfile;
    await tester.runAsync(() async {
      customProfile = await profiles.create('Custom', photoUrl: photoUrl);
    });
    GetIt.instance.registerSingleton<AuthCubit>(_PhotoAuthCubit());

    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );
    await tester.pumpAndSettle();

    final avatar = find.byKey(
      ValueKey('profile-avatar-fill-${customProfile!.id}'),
    );
    final imageFinder = find.descendant(
      of: avatar,
      matching: find.byType(Image),
    );
    expect(imageFinder, findsOneWidget);
    final image = tester.widget<Image>(imageFinder);
    final resized = image.image as ResizeImage;
    expect(resized.imageProvider, isA<CachedNetworkImageProvider>());
    expect((resized.imageProvider as CachedNetworkImageProvider).url, photoUrl);
    expect(image.frameBuilder, same(imageFadeIn));
    expect(image.filterQuality, FilterQuality.high);
    expect(
      find.descendant(of: avatar, matching: find.byType(ClipOval)),
      findsOneWidget,
    );
  });

  testWidgets('manager tile shows the account photo for the default profile', (
    tester,
  ) async {
    GetIt.instance.registerSingleton<AuthCubit>(_PhotoAuthCubit());
    await tester.pumpWidget(const MaterialApp(home: ViewerProfilesScreen()));
    await tester.pumpAndSettle();
    final defaultId = profiles.profiles.first.id;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('profile-tile-avatar-$defaultId')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });

  testWidgets('manager tile shows the photo saved on its profile', (
    tester,
  ) async {
    const photoUrl = 'https://cdn.example/custom-profile.jpg';
    ViewerProfile? customProfile;
    await tester.runAsync(() async {
      customProfile = await profiles.create('Custom', photoUrl: photoUrl);
    });

    await tester.pumpWidget(const MaterialApp(home: ViewerProfilesScreen()));
    await tester.pumpAndSettle();

    final avatar = find.byKey(
      ValueKey('profile-tile-avatar-${customProfile!.id}'),
    );
    final image = tester.widget<Image>(
      find.descendant(of: avatar, matching: find.byType(Image)),
    );
    expect(
      (image.image as ResizeImage).imageProvider,
      isA<CachedNetworkImageProvider>(),
    );
    expect(image.frameBuilder, same(imageFadeIn));
    expect(
      find.descendant(of: avatar, matching: find.byType(ClipOval)),
      findsOneWidget,
    );
  });

  testWidgets('editing a profile opens a full page and can be cancelled', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ViewerProfilesScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit Home'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Edit profile'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(profiles.profiles.first.name, 'Home');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('picker greets the active profile', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ready for the next watch, Home?'), findsOneWidget);
  });

  testWidgets('picker greeting follows a rename', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => profiles.rename(profiles.profiles.first.id, 'Evening'),
    );
    await tester.pump();
    expect(find.text('Ready for the next watch, Evening?'), findsOneWidget);
  });
}

class _PhotoAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _PhotoAuthCubit()
    : super(
        const AuthState(
          status: AuthStatus.authenticated,
          avatarUrl: 'https://example.com/pic.png',
        ),
      );

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _SeededHomeCubit extends HomeCubit {
  _SeededHomeCubit(this._seed) : super(_UnusedCatalogueRepository());

  final HomeState _seed;

  @override
  HomeState get state => _seed;
}

class _UnusedCatalogueRepository implements CatalogueRepository {
  @override
  noSuchMethod(Invocation invocation) =>
      throw StateError('The profile picker must not fetch Home data');
}

class _ProfileGateShellProbe extends StatelessWidget {
  const _ProfileGateShellProbe({required this.onBuild});

  final ValueChanged<bool> onBuild;

  @override
  Widget build(BuildContext context) {
    final deferContent = ProfileShellScope.shouldDeferContent(context);
    onBuild(deferContent);
    return deferContent ? const SizedBox.expand() : const Text('Main screen');
  }
}

class _ProfileGateHeroProbe extends StatelessWidget {
  const _ProfileGateHeroProbe({required this.profiles});

  final ViewerProfileStore profiles;

  @override
  Widget build(BuildContext context) {
    if (ProfileShellScope.shouldDeferContent(context)) {
      return const SizedBox.expand();
    }
    return ValueListenableBuilder<ViewerProfile?>(
      valueListenable: profiles.active,
      builder: (context, profile, _) => Align(
        alignment: Alignment.bottomCenter,
        child: profile == null
            ? const SizedBox.shrink()
            : Hero(
                tag: viewerProfileHeroTag(profile.id),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: viewerProfileAvatarColor(profile.avatar),
                  ),
                  child: ProfileAvatarFace(
                    profile: profile,
                    iconSize: 14,
                    photoDiameter: 24,
                  ),
                ),
              ),
      ),
    );
  }
}
