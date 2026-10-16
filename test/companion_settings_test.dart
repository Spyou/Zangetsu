import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_theme.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/companion/remote_panel.dart';
import 'package:watch_app/features/companion/remote_session.dart';
import 'package:watch_app/features/companion/companion_settings_screen.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('TV settings can navigate back up to the QR code', (
    tester,
  ) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    addTearDown(() => sl.unregister<AppMode>());
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RemoteSession.channel, (call) async {
      if (call.method == 'receiverState')
        return {
          'hosting': true,
          'qr': 'test-pairing',
          'pin': '123456',
          'address': '192.168.1.2:1234',
        };
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(RemoteSession.channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const CompanionSettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scroll.position.pixels, greaterThan(0));
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }
    expect(scroll.position.pixels, lessThan(100));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  const state = <String, dynamic>{
    'active': true,
    'appForeground': true,
    'playerForeground': true,
    'canSkipIntro': true,
    'megaSkipEnabled': true,
    'megaSkipSeconds': 85,
    'title': 'Fire Force',
    'episodeLabel': 'Episode 1 · Salamander Combat Team',
    'playing': true,
    'positionMs': 250000,
    'durationMs': 1420000,
    'volume': 80,
    'episodeIndex': 0,
  };
  Widget panel(
    List<String> actions, {
    Map<String, dynamic>? snapshot,
    double dock = 90,
    double textScale = 1,
    bool inTab = false,
    EdgeInsets insets = EdgeInsets.zero,
  }) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        padding: insets,
        viewPadding: insets,
      ),
      child: child!,
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('Remote')),
      body: Padding(
        padding: EdgeInsets.only(bottom: dock, top: 12),
        child: RemotePanel(
          inRemoteTab: inTab,
          connected: true,
          name: 'MselekuTV',
          status: 'Bluetooth · Wi-Fi ready',
          remoteMode: false,
          state: snapshot ?? state,
          companionReady: (snapshot ?? state)['appForeground'] != false,
          onMode: (_) {},
          onManage: () {},
          onScan: () {},
          onSearch: () {},
          onShortcut: (action) => actions.add(action),
          command: (action, values) =>
              actions.add(action == 'key' ? values['value'] as String : action),
        ),
      ),
    ),
  );
  for (final size in [
    const Size(360, 800),
    const Size(320, 640),
    const Size(390, 844),
    const Size(430, 932),
    const Size(800, 600),
    const Size(800, 400),
  ]) {
    testWidgets('compact remote fits ${size.width} without scrolling', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final actions = <String>[];
      await tester.pumpWidget(panel(actions));
      await tester.pump();
      expect(find.byType(Scrollable), findsNothing);
      expect(tester.takeException(), isNull);
      final pad = tester.getRect(find.byType(CircularRemotePad));
      final finger = await tester.startGesture(
        pad.center + Offset(pad.width * .37, 0),
      );
      expect(actions, ['right'], reason: 'Press goes out before finger lifts');
      await finger.up();
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(actions, ['right', 'release', 'toggle']);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('tab anchors playback above dock without enlarging D-pad', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(panel([]));
    final pad = tester.getSize(find.byType(CircularRemotePad));
    final volume = tester.getBottomLeft(find.byTooltip('TV volume up')).dy;
    await tester.pumpWidget(panel([], inTab: true));
    expect(tester.getSize(find.byType(CircularRemotePad)), pad);
    expect(
      tester.getBottomLeft(find.byTooltip('TV volume up')).dy,
      greaterThan(volume),
    );
    expect(
      tester.getBottomLeft(find.byTooltip('TV volume up')).dy,
      closeTo(702, 5),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('same phone keeps the same D-pad on either entry route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(panel([]));
    final tabPad = tester.getSize(find.byType(CircularRemotePad));
    await tester.pumpWidget(panel([], dock: 0));
    expect(tester.getSize(find.byType(CircularRemotePad)), tabPad);
  });
  testWidgets('shortcuts work directly with larger text and safe insets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final actions = <String>[];
    await tester.pumpWidget(
      panel(
        actions,
        textScale: 1.3,
        insets: const EdgeInsets.only(top: 32, bottom: 24),
      ),
    );
    expect(tester.takeException(), isNull);
    for (final label in [
      'Continue on phone',
      'Episodes',
      'Sources',
      'Quality',
      'Audio',
      'Subtitles',
    ]) {
      await tester.tap(find.byTooltip(label));
    }
    expect(actions, [
      'phone',
      'episodes',
      'sources',
      'quality',
      'audio',
      'subtitles',
    ]);
    expect(find.byTooltip('Playback options'), findsNothing);
  });
  testWidgets('render remote preview using the app font', (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final font = FontLoader('Nunito')
      ..addFont(rootBundle.load('assets/fonts/Nunito-Regular.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '${Platform.environment['FLUTTER_ROOT'] ?? '../flutter'}/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
    await tester.pumpWidget(
      RepaintBoundary(key: const Key('preview'), child: panel([], inTab: true)),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('preview')),
      matchesGoldenFile('goldens/remote.png'),
    );
  });
  testWidgets('skip controls follow the TV settings and foreground state', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(panel(actions));
    expect(find.text('Mega Skip +85s'), findsOneWidget);
    await tester.tap(find.text('Mega Skip +85s'));
    expect(actions, ['megaSkip']);
    await tester.pumpWidget(
      panel(
        actions,
        snapshot: {...state, 'megaSkipSeconds': 120, 'canSkipIntro': false},
      ),
    );
    expect(find.text('Mega Skip +120s'), findsOneWidget);
    expect(find.text('Skip Intro'), findsNothing);
    await tester.pumpWidget(
      panel(
        actions,
        snapshot: {...state, 'megaSkipEnabled': false, 'canSkipIntro': false},
      ),
    );
    expect(find.textContaining('Mega Skip'), findsNothing);
    await tester.pumpWidget(
      panel(actions, snapshot: {...state, 'appForeground': false}),
    );
    expect(find.text('Fire Force'), findsNothing);
    expect(find.byTooltip('Pause'), findsNothing);
    expect(find.byTooltip('Next episode'), findsNothing);
    expect(find.text('Search'), findsNothing);
    expect(find.byTooltip('TV volume up'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });
  testWidgets('rapid taps send one movement each and ignore a second finger', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(panel(actions));
    final pad = tester.getRect(find.byType(CircularRemotePad));
    final right = pad.center + Offset(pad.width * .37, 0);
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(right);
    }
    expect(actions, List.generate(10, (i) => i.isEven ? 'right' : 'release'));
    actions.clear();
    final first = await tester.startGesture(right, pointer: 1);
    final second = await tester.startGesture(pad.center, pointer: 2);
    await second.up();
    expect(actions, ['right']);
    await first.up();
    expect(actions, ['right', 'release']);
  });
  testWidgets('failed background companion probe preserves Bluetooth control', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RemoteSession.channel, (call) async {
      if (call.method == 'connectionState')
        return {'connected': true, 'hid': true, 'companion': false};
      if (call.method == 'command')
        throw PlatformException(
          code: 'connection',
          message: 'Connection changed',
        );
      return null;
    });
    final remote = RemoteSession();
    await remote.refreshConnection();
    await expectLater(
      remote.command('state'),
      throwsA(isA<PlatformException>()),
    );
    expect(remote.connected, isTrue);
    expect(remote.error, isNull);
    remote.dispose();
    messenger.setMockMethodCallHandler(RemoteSession.channel, null);
  });
  testWidgets('connection survives page changes and commands stay ordered', (
    tester,
  ) async {
    const channel = RemoteSession.channel;
    final calls = <String>[];
    final gate = Completer<String>();
    var count = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'connectionState')
            return {'connected': true, 'saved': true, 'name': 'TV'};
          if (call.method == 'command') {
            final request = jsonDecode(call.arguments as String);
            calls.add(request['action'] as String);
            if (++count == 1) return gate.future;
            return jsonEncode({'ok': true});
          }
          if (call.method == 'control') {
            calls.add(jsonDecode(call.arguments as String)['action'] as String);
            return '{}';
          }
          return null;
        });
    final remote = RemoteSession();
    await remote.refreshConnection();
    final first = remote.command('state');
    final second = remote.command('key', {'value': 'ok'});
    await tester.pump();
    expect(calls, isNot(contains('key')));
    await remote.control('release');
    expect(
      calls,
      contains('release'),
      reason: 'Releasing a held key must bypass a pending companion request',
    );
    gate.complete(jsonEncode(state));
    await tester.pump();
    await first;
    await second;
    expect(calls.where((e) => ['state', 'key'].contains(e)), ['state', 'key']);
    await tester.pumpWidget(const SizedBox());
    expect(calls, isNot(contains('disconnect')));
    remote.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('existing dock gains Remote before Profile', () {
    expect(
      NavPrefs.sanitizeForTest([
        DockTab.home,
        DockTab.myList,
        DockTab.sources,
        DockTab.profile,
      ]),
      [
        DockTab.home,
        DockTab.myList,
        DockTab.sources,
        DockTab.remote,
        DockTab.profile,
      ],
    );
  });
}
