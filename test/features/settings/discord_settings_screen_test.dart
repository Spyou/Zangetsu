import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/features/settings/discord_settings_screen.dart';

class _Discord extends DiscordRpc {
  _Discord() : super(Dio());
  bool connected = true;
  bool active = true;
  final preferences = <String, Object>{};

  @override
  bool get loggedIn => connected;
  @override
  bool get enabled => active;
  @override
  String get displayName => 'Krishna';
  @override
  String get username => 'krishna';
  @override
  String get avatarUrl => '';
  @override
  String get nameSrc => 'title';
  @override
  String get detailsSrc => 'episode';
  @override
  String get stateSrc => 'app';
  @override
  String get presenceStatus => 'online';
  @override
  String get largeImageSrc => 'poster';
  @override
  String get smallImageSrc => 'logo';
  @override
  bool get showPresenceButton => true;
  @override
  String get presenceButtonLabel => '';
  @override
  bool get showWhenPaused => preferences['showPaused'] as bool? ?? true;
  @override
  bool get browsingShowsTitle => preferences['browsingTitle'] as bool? ?? true;
  @override
  Future<void> setEnabled(bool value) async => active = value;
  @override
  Future<void> setPresencePref(String key, Object value) async {
    preferences[key] = value;
  }
}

void main() {
  late _Discord rpc;
  setUp(() async {
    await sl.reset();
    rpc = _Discord();
    sl.registerSingleton<DiscordRpc>(rpc);
  });
  tearDown(() => sl.reset());

  Widget screen() => const MaterialApp(home: DiscordSettingsScreen());

  testWidgets(
    'simple settings retain useful switches and remove advanced rows',
    (tester) async {
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      for (final label in [
        'Large image',
        'Small image',
        'State shows',
        'Name shows',
        'Details show',
        'Activity status',
        'Open button',
        'Button label',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.byType(Switch), findsNWidgets(3));
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(rpc.enabled, isFalse);
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      expect(rpc.preferences['showPaused'], isFalse);
    },
  );

  for (final width in [320.0, 800.0]) {
    testWidgets('Bleach preview fits width $width with large text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const DiscordSettingsScreen(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Watching BLEACH: Thousand-Year Blood War'),
        250,
      );
      final heading = find.text('Watching BLEACH: Thousand-Year Blood War');
      final episode = find.text('Episode 1 · The Blood Warfare');
      expect(episode, findsOneWidget);
      expect(
        tester.getTopLeft(heading).dy,
        lessThan(tester.getTopLeft(episode).dy),
      );
      expect(find.text('12:00'), findsOneWidget);
      expect(find.text('24:00'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is AssetImage,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('signed-out screen offers connection without account controls', (
    tester,
  ) async {
    rpc.connected = false;
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(find.text('Connect Discord'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Krishna'), findsNothing);
  });
}
