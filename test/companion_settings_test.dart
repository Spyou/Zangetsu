import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/theme/app_text.dart';
import 'package:watch_app/core/theme/app_theme.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/companion/glass_pad.dart';
import 'package:watch_app/features/companion/remote_panel.dart';
import 'package:watch_app/features/companion/remote_prefs.dart';
import 'package:watch_app/features/companion/remote_session.dart';
import 'package:watch_app/features/companion/companion_settings_screen.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _remoteErrorTests();
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
      // Only the shortcut chips scroll, sideways; the remote never scrolls.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Scrollable &&
              axisDirectionToAxis(w.axisDirection) == Axis.vertical,
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      final pad = tester.getRect(find.byType(GlassPad));
      final finger = await tester.startGesture(
        Offset(pad.center.dx - pad.width * .18, pad.top + pad.height * .22),
      );
      await finger.moveBy(const Offset(30, 0));
      await finger.moveBy(const Offset(30, 0));
      expect(actions, ['right'], reason: 'Each swipe step goes out at once');
      await finger.up();
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(actions, ['right', 'toggle']);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('remote fills its height on either entry route', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(panel([]));
    final pad = tester.getSize(find.byType(GlassPad));
    final volume = tester.getBottomLeft(find.byTooltip('TV volume up')).dy;
    await tester.pumpWidget(panel([], inTab: true));
    expect(tester.getSize(find.byType(GlassPad)), pad);
    expect(tester.getBottomLeft(find.byTooltip('TV volume up')).dy, volume);
    // Bottom row sits just above the reserved dock space.
    expect(volume, closeTo(800 - 90 - 8, 6));
    await tester.pumpWidget(panel([], dock: 0));
    expect(
      tester.getSize(find.byType(GlassPad)).height,
      greaterThan(pad.height),
    );
    expect(tester.takeException(), isNull);
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
      await tester.ensureVisible(find.byTooltip(label));
      await tester.pumpAndSettle();
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
    AppText.fontFamily = 'Nunito';
    addTearDown(() => AppText.fontFamily = AppText.defaultFontFamily);
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
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('preview'),
        child: panel([], inTab: true, snapshot: {...state, 'active': false}),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('preview')),
      matchesGoldenFile('goldens/remote_idle.png'),
    );
  });
  testWidgets('skip controls follow the TV settings and foreground state', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(panel(actions));
    expect(find.byTooltip('Mega Skip +85s'), findsOneWidget);
    expect(find.text('+85s'), findsOneWidget);
    await tester.tap(find.byTooltip('Mega Skip +85s'));
    expect(actions, ['megaSkip']);
    await tester.pumpWidget(
      panel(
        actions,
        snapshot: {...state, 'megaSkipSeconds': 120, 'canSkipIntro': false},
      ),
    );
    expect(find.byTooltip('Mega Skip +120s'), findsOneWidget);
    expect(find.text('Skip Intro'), findsNothing);
    await tester.pumpWidget(
      panel(
        actions,
        snapshot: {...state, 'megaSkipEnabled': false, 'canSkipIntro': false},
      ),
    );
    expect(find.byTooltip('Mega Skip +85s'), findsNothing);
    expect(find.text('+85s'), findsNothing);
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
  testWidgets('rapid taps send one OK each and ignore a second finger', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      panel(actions, snapshot: {...state, 'active': false}),
    );
    final pad = tester.getRect(find.byType(GlassPad));
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(pad.center);
    }
    expect(actions, List.filled(5, 'ok'));
    actions.clear();
    final first = await tester.startGesture(pad.center, pointer: 1);
    final second = await tester.startGesture(
      pad.topCenter + const Offset(0, 40),
      pointer: 2,
    );
    await second.up();
    expect(actions, isEmpty);
    await first.moveBy(const Offset(60, 0));
    await first.up();
    expect(actions, ['right']);
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
  test('the dock no longer gains a Remote tab (it lives in Profile)', () {
    final dock = [
      DockTab.home,
      DockTab.myList,
      DockTab.sources,
      DockTab.profile,
    ];
    expect(NavPrefs.sanitizeForTest(dock), dock);
  });
  _bluetoothSearchTests();
}

void _remoteErrorTests() {
  test('remote errors read as plain sentences', () {
    expect(
      RemoteSession.userMessage(
        PlatformException(code: 'connection', message: 'Bad state: TV gone'),
      ),
      'TV gone',
    );
    expect(
      RemoteSession.userMessage(StateError('Scan it first.')),
      'Scan it first.',
    );
    expect(
      RemoteSession.userMessage(PlatformException(code: 'connection')),
      'Lost connection to the TV.',
    );
  });

  test('a successful remote command clears the last command error', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RemoteSession.channel, (call) async {
      if (call.method == 'command') return '{}';
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(RemoteSession.channel, null),
    );
    final session = RemoteSession()
      ..connected = true
      ..error = 'Reconnect to your TV first.';
    await session.command('seek', {'value': 1000});
    expect(session.error, isNull);
  });
}

/// Contract item 7: "Pair a new Bluetooth TV" searches from the phone instead
/// of making the phone discoverable.
void _bluetoothSearchTests() {
  group('Find your TV sheet', () {
    const tvAddress = 'AA:BB:CC:DD:EE:FF';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Completer<Map<String, dynamic>>? pairGate;

    Future<Object?> handler(MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'connectionState':
          return {'connected': false, 'saved': false};
        case 'bluetoothScanResults':
          return {
            'scanning': true,
            'devices': [
              {
                'name': 'Living Room TV',
                'address': tvAddress,
                'bonded': false,
                'tv': true,
                'bonding': false,
              },
            ],
          };
        case 'bluetoothPair':
          pairGate = Completer<Map<String, dynamic>>();
          return pairGate!.future;
      }
      return null;
    }

    List<String> methods() => calls.map((c) => c.method).toList();

    // The app-wide session keeps a 1 s poller alive for the app's lifetime;
    // start it outside the fake clock so no test ends with a pending timer.
    // The phone screen loads RemotePrefs from Hive; open its box here, outside
    // the fake clock, so the screen never does real disk work mid-test.
    late Directory hiveDir;
    setUpAll(() async {
      hiveDir = await Directory.systemTemp.createTemp('remote_prefs_test');
      Hive.init(hiveDir.path);
      await Hive.openBox(RemotePrefs.boxName);
      messenger.setMockMethodCallHandler(RemoteSession.channel, handler);
      await RemoteSession.instance.start();
    });
    tearDownAll(() async {
      RemoteSession.instance.dispose();
      messenger.setMockMethodCallHandler(RemoteSession.channel, null);
      await Hive.close();
      try {
        await hiveDir.delete(recursive: true);
      } catch (_) {}
    });
    setUp(() {
      calls.clear();
      pairGate = null;
      messenger.setMockMethodCallHandler(RemoteSession.channel, handler);
    });

    // The scan sheet shows an endless spinner, so pumpAndSettle never settles.
    Future<void> settle(WidgetTester tester, [int steps = 6]) async {
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> openFindYourTv(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: const CompanionSettingsScreen(),
        ),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('Manage connection'));
      await settle(tester);
      final pair = find.text('Pair a new Bluetooth TV');
      await tester.ensureVisible(pair);
      await settle(tester, 2);
      expect(find.text('Search for your TV from this phone'), findsOneWidget);
      await tester.tap(pair);
      // Long enough for at least one 1 s results poll.
      await settle(tester, 15);
    }

    testWidgets('searches from the phone and lists the TV', (tester) async {
      await openFindYourTv(tester);
      expect(find.text('Find your TV'), findsOneWidget);
      expect(methods(), contains('bluetoothScan'));
      expect(methods(), isNot(contains('pairBluetooth')));
      expect(methods(), contains('bluetoothScanResults'));
      expect(find.text('Searching…'), findsOneWidget);
      expect(find.text('Living Room TV'), findsOneWidget);
      expect(find.textContaining('so it can be found'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('tapping a TV pairs with its address', (tester) async {
      await openFindYourTv(tester);
      await tester.tap(find.text('Living Room TV'));
      await settle(tester, 3);
      final pair = calls.where((c) => c.method == 'bluetoothPair').toList();
      expect(pair, hasLength(1));
      expect(pair.single.arguments, tvAddress);
      expect(find.text('Confirm the code on your TV'), findsOneWidget);
      pairGate!.complete({'name': 'Living Room TV', 'address': tvAddress});
      await settle(tester, 10);
      expect(find.text('Find your TV'), findsNothing);
      expect(methods(), contains('bluetoothScanStop'));
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('closing the sheet stops the search', (tester) async {
      await openFindYourTv(tester);
      expect(methods(), isNot(contains('bluetoothScanStop')));
      Navigator.of(tester.element(find.text('Find your TV'))).pop();
      await settle(tester, 10);
      expect(find.text('Find your TV'), findsNothing);
      expect(methods(), contains('bluetoothScanStop'));
      // Polling stops with the sheet.
      final polls = methods().where((m) => m == 'bluetoothScanResults').length;
      await settle(tester, 25);
      expect(methods().where((m) => m == 'bluetoothScanResults').length, polls);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('fallback lets the TV find this phone', (tester) async {
      await openFindYourTv(tester);
      final fallback = find.text('Let the TV find this phone instead');
      await tester.ensureVisible(fallback);
      await settle(tester, 2);
      expect(
        find.text('Then choose this phone in TV › Remotes & accessories'),
        findsOneWidget,
      );
      await tester.tap(fallback);
      await settle(tester, 3);
      expect(methods(), contains('pairBluetooth'));
      expect(methods(), isNot(contains('bluetoothPair')));
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });
  });
}
