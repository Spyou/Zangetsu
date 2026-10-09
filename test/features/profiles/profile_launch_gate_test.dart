import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/profiles/profile_shell_scope.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/tv/tv_list_focusable.dart';
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

  testWidgets('launch picker uses round profile avatars and an add avatar', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ViewerProfilesScreen(selectionOnly: true)),
    );

    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.text('Select a profile to continue'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(
      find.byKey(ValueKey('profile-avatar-fill-${profiles.profiles.first.id}')),
      findsOneWidget,
    );
    expect(find.text('Add profile'), findsOneWidget);
  });

  testWidgets('launch picker uses the app background and a two-column grid', (
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

    expect(find.byIcon(Icons.check_rounded), findsNothing);
    final profileAvatars = profiles.profiles
        .map(
          (profile) =>
              find.byKey(ValueKey('profile-avatar-fill-${profile.id}')),
        )
        .toList();
    expect(profileAvatars, hasLength(ViewerProfileStore.maxProfiles));
    for (final avatar in profileAvatars) {
      expect(tester.getSize(avatar).width, greaterThanOrEqualTo(100));
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
      inInclusiveRange(165, 180),
    );
    expect(tester.getSize(gridFinder).width, inInclusiveRange(260, 380));
    expect(grid.childrenDelegate, isA<SliverChildListDelegate>());
    expect(
      (grid.childrenDelegate as SliverChildListDelegate).children.length,
      ViewerProfileStore.maxProfiles,
    );
  });

  testWidgets(
    'avatar tap feedback is circular under one entrance wrapper',
    (tester) async {
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
      expect(
        tester.widget<SlideTransition>(screenSlide).child,
        isA<Scaffold>(),
      );
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
      expect(ripple.splashColor, AppColors.textPrimary.withValues(alpha: 0.28));
      final fill = tester.widget<Material>(
        find.byKey(ValueKey('profile-avatar-fill-${profile.id}')),
      );
      expect(fill.color, AppColors.accent);
      expect(fill.shape, isA<CircleBorder>());
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
    },
  );

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
    expect(find.text('Add profile'), findsNothing);

    await tester.tap(find.text('Manage profiles'));
    await tester.pumpAndSettle();

    expect(find.text('Profiles'), findsOneWidget);
    expect(find.byTooltip('Delete Profile 1'), findsOneWidget);
    expect(find.byTooltip('Delete Profile 2'), findsOneWidget);
    expect(find.byTooltip('Delete Profile 3'), findsOneWidget);
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
    expect(find.text('Who is watching?'), findsNothing);
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
    final footerFade = find.byKey(
      const ValueKey('profile-picker-footer-fade'),
    );
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

  testWidgets('double-tap selects once', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ProfileLaunchGate(child: Text('Main screen'))),
    );
    await tester.pumpAndSettle();
    final id = profiles.profiles.first.id;
    final ink = find.byKey(ValueKey('profile-avatar-ink-$id'));
    await tester.tap(ink);
    await tester.pump(); // real taps always span frames
    await tester.tap(ink);
    await tester.pumpAndSettle();
    expect(find.text('Main screen'), findsOneWidget);
    expect(find.text("Who's watching?"), findsNothing);
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
