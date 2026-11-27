import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_theme.dart';
import 'package:watch_app/features/companion/glass_pad.dart';
import 'package:watch_app/features/companion/remote_panel.dart';
import 'package:watch_app/features/companion/remote_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(RemotePrefs.instance.resetForTest);

  const browsing = <String, dynamic>{'active': false, 'appForeground': true};
  const playing = <String, dynamic>{
    'active': true,
    'appForeground': true,
    'playerForeground': true,
    'canSkipIntro': true,
    'skipLabel': 'Skip Recap',
    'megaSkipEnabled': true,
    'megaSkipSeconds': 90,
    'title': 'Fire Force',
    'episodeLabel': 'Episode 1',
    'playing': true,
    'positionMs': 61000,
    'durationMs': 1420000,
  };

  /// Records `action` or `key:value[:phase]` for every command.
  Future<List<String>> pump(
    WidgetTester tester, {
    Map<String, dynamic> state = browsing,
    bool connected = true,
    bool keyboard = false,
    bool remoteMode = false,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: RemotePanel(
            connected: connected,
            name: 'Living room',
            status: 'Scan your TV to connect',
            remoteMode: remoteMode,
            state: state,
            companionReady: state['appForeground'] != false,
            onMode: (v) => sent.add('mode:$v'),
            onManage: () => sent.add('manage'),
            onScan: () => sent.add('scan'),
            onSearch: () => sent.add('search'),
            onShortcut: (s) => sent.add('shortcut:$s'),
            onKeyboard: keyboard ? () => sent.add('keyboard') : null,
            command: (action, values) => sent.add(
              [
                action,
                if (values['value'] != null) values['value'],
                if (values['phase'] != null) values['phase'],
              ].join(':'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return sent;
  }

  Rect pad(WidgetTester tester) => tester.getRect(find.byType(GlassPad));

  /// A point on the surface that is clear of the playing overlay's buttons.
  Offset start(WidgetTester tester) {
    final r = pad(tester);
    return Offset(r.center.dx - r.width * .18, r.top + r.height * .22);
  }

  testWidgets('swipe right sends key right, a long drag several steps', (
    tester,
  ) async {
    final sent = await pump(tester);
    final finger = await tester.startGesture(start(tester));
    await finger.moveBy(const Offset(30, 0));
    await finger.moveBy(const Offset(30, 0));
    expect(sent, ['key:right']);
    await finger.moveBy(const Offset(45, 0));
    await finger.moveBy(const Offset(45, 0));
    expect(sent, ['key:right', 'key:right', 'key:right']);
    await finger.up();
    expect(sent, ['key:right', 'key:right', 'key:right']);
    sent.clear();
    final up = await tester.startGesture(pad(tester).center);
    await up.moveBy(const Offset(4, -30));
    await up.moveBy(const Offset(0, -30));
    await up.up();
    expect(sent, ['key:up']);
  });

  testWidgets('tap sends OK and a second finger is ignored', (tester) async {
    final sent = await pump(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(pad(tester).center);
    }
    expect(sent, ['key:ok', 'key:ok', 'key:ok']);
    sent.clear();
    final first = await tester.startGesture(start(tester), pointer: 1);
    final second = await tester.startGesture(pad(tester).center, pointer: 2);
    await second.up();
    expect(sent, isEmpty);
    await first.moveBy(const Offset(0, 50));
    await first.up();
    expect(sent, ['key:down']);
  });

  testWidgets('resting after a swipe holds with press, lifting releases', (
    tester,
  ) async {
    final sent = await pump(tester);
    final finger = await tester.startGesture(start(tester));
    await finger.moveBy(const Offset(25, 0));
    await finger.moveBy(const Offset(25, 0));
    expect(sent, ['key:right']);
    await tester.pump(const Duration(milliseconds: 600));
    expect(sent, ['key:right', 'key:right:press']);
    await tester.pump(const Duration(seconds: 1));
    await finger.up();
    expect(sent, ['key:right', 'key:right:press', 'release']);
    sent.clear();
    // Moving off the resting point ends the hold and stepping resumes.
    final again = await tester.startGesture(start(tester));
    await again.moveBy(const Offset(0, 25));
    await again.moveBy(const Offset(0, 25));
    await tester.pump(const Duration(milliseconds: 600));
    await again.moveBy(const Offset(0, 25));
    await again.moveBy(const Offset(0, 50));
    await again.up();
    expect(sent, ['key:down', 'key:down:press', 'release', 'key:down']);
  });

  testWidgets('nothing moves or taps when disconnected; scan stays', (
    tester,
  ) async {
    final sent = await pump(tester, connected: false, state: const {});
    final finger = await tester.startGesture(pad(tester).center);
    await finger.moveBy(const Offset(80, 0));
    await finger.up();
    await tester.tapAt(pad(tester).center);
    expect(sent, isEmpty);
    expect(find.text('Your TV'), findsOneWidget);
    expect(find.text('Scan your TV to connect'), findsOneWidget);
    await tester.tap(find.text('Scan to connect'));
    expect(sent, ['scan']);
  });

  testWidgets('icons-only hides names but keeps tooltips', (tester) async {
    final sent = await pump(
      tester,
      keyboard: true,
      state: {...browsing, 'keyboardVersion': 1},
    );
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Keyboard'), findsOneWidget);
    await tester.tap(find.byTooltip('Remote options'));
    await tester.pumpAndSettle();
    expect(find.text('Manage connection'), findsOneWidget);
    await tester.tap(find.text('Show button names'));
    await tester.pumpAndSettle();
    expect(RemotePrefs.instance.showLabels, isFalse);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    for (final name in ['Back', 'Home', 'Search', 'Keyboard']) {
      expect(find.text(name), findsNothing, reason: name);
      expect(find.byTooltip(name), findsOneWidget, reason: name);
    }
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Search'), findsOneWidget);
    semantics.dispose();
    await tester.tap(find.byTooltip('Search'));
    expect(sent, ['search']);
    // The sheet's Manage connection matches the pill.
    await tester.tap(find.byTooltip('Remote options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage connection'));
    await tester.pumpAndSettle();
    expect(sent, ['search', 'manage']);
    await tester.tap(find.byTooltip('Manage connection'));
    expect(sent, ['search', 'manage', 'manage']);
  });

  testWidgets('idle buttons keep their commands', (tester) async {
    final sent = await pump(
      tester,
      keyboard: true,
      state: {
        ...browsing,
        'keyboardVersion': 1,
        'keyboard': <String, dynamic>{'field': 1},
      },
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.tap(find.byTooltip('Home'));
    await tester.tap(find.byTooltip('Search'));
    await tester.tap(find.byTooltip('Keyboard'));
    // The volume tooltips sit under IgnorePointer; the held Listener above
    // them takes the touch, so the hit-test warning does not apply.
    await tester.tap(find.byTooltip('TV volume up'), warnIfMissed: false);
    await tester.tap(find.byTooltip('Mute TV'));
    await tester.tap(find.byTooltip('TV volume down'), warnIfMissed: false);
    await tester.tap(find.byType(Switch));
    expect(sent, [
      'key:back',
      'home',
      'search',
      'keyboard',
      'volumeUp:press',
      'release',
      'mute',
      'volumeDown:press',
      'release',
      'mode:true',
    ]);
    final badge = tester.widget<Badge>(
      find.ancestor(
        of: find.byIcon(Icons.keyboard_alt_outlined),
        matching: find.byType(Badge),
      ),
    );
    expect(badge.isLabelVisible, isTrue);
  });

  testWidgets('volume buttons hold to repeat and follow volumeAvailable', (
    tester,
  ) async {
    var sent = await pump(tester);
    final finger = await tester.startGesture(
      tester.getCenter(find.byTooltip('TV volume up')),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(sent, ['volumeUp:press']);
    await finger.up();
    expect(sent, ['volumeUp:press', 'release']);
    sent = await pump(tester, state: {...browsing, 'volumeAvailable': false});
    await tester.tap(find.byTooltip('TV volume up'), warnIfMissed: false);
    await tester.tap(find.byTooltip('Mute TV'), warnIfMissed: false);
    expect(sent, isEmpty);
  });

  testWidgets('keyboard pill only for keyboardVersion 1 while browsing', (
    tester,
  ) async {
    await pump(tester, keyboard: true);
    expect(find.byTooltip('Keyboard'), findsNothing);
    await pump(
      tester,
      keyboard: true,
      state: {...browsing, 'keyboardVersion': 2},
    );
    expect(find.byTooltip('Keyboard'), findsNothing);
    await pump(tester, state: {...browsing, 'keyboardVersion': 1});
    expect(find.byTooltip('Keyboard'), findsNothing);
    await pump(
      tester,
      keyboard: true,
      state: {...playing, 'keyboardVersion': 1},
    );
    expect(find.byTooltip('Keyboard'), findsNothing);
    await pump(
      tester,
      keyboard: true,
      state: {...browsing, 'keyboardVersion': 1},
    );
    expect(find.byTooltip('Keyboard'), findsOneWidget);
  });

  testWidgets('browse switch and search only while browsing', (tester) async {
    await pump(tester);
    expect(find.text('Browse on phone, play on TV'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.text('Browsing Zangetsu'), findsOneWidget);
    await pump(tester, state: playing);
    expect(find.text('Browse on phone, play on TV'), findsNothing);
    expect(find.byTooltip('Search'), findsNothing);
    await pump(tester, state: {...browsing, 'appForeground': false});
    expect(find.text('Browse on phone, play on TV'), findsNothing);
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byTooltip('TV volume up'), findsOneWidget);
    await pump(tester, connected: false, state: const {});
    expect(find.text('Browse on phone, play on TV'), findsNothing);
  });

  testWidgets('playing shows the card, skip, mega skip and shortcuts', (
    tester,
  ) async {
    final sent = await pump(tester, state: playing);
    expect(find.text('Fire Force'), findsOneWidget);
    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    expect(find.text('23:40'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    await tester.tap(find.text('Skip Recap'));
    await tester.tap(find.byTooltip('Mega Skip +90s'));
    await tester.tap(find.byTooltip('Pause'));
    await tester.tap(find.byTooltip('Back 10 seconds'));
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.tap(find.byTooltip('Previous episode'));
    await tester.tap(find.byTooltip('Next episode'));
    await tester.tap(find.byTooltip('Back'));
    await tester.tap(find.byTooltip('Home'));
    expect(sent, [
      'skipIntro',
      'megaSkip',
      'toggle',
      'rewind',
      'forward',
      'previous',
      'next',
      'key:back',
      'home',
    ]);
    sent.clear();
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
    expect(sent, [
      'shortcut:phone',
      'shortcut:episodes',
      'shortcut:sources',
      'shortcut:quality',
      'shortcut:audio',
      'shortcut:subtitles',
    ]);
    sent.clear();
    // The surface still moves, a tap pauses and a long press is OK.
    final finger = await tester.startGesture(start(tester));
    await finger.moveBy(const Offset(-30, 0));
    await finger.moveBy(const Offset(-30, 0));
    await finger.up();
    await tester.tapAt(start(tester));
    await tester.longPressAt(start(tester));
    expect(sent, ['key:left', 'toggle', 'key:ok']);
    expect(find.text('Swipe to move · tap to pause'), findsOneWidget);
  });

  testWidgets('seek slider sends positionMs on release', (tester) async {
    final sent = await pump(tester, state: playing);
    final slider = find.byType(Slider);
    await tester.tapAt(tester.getCenter(slider));
    await tester.pump();
    expect(sent.single, 'seek');
    await pump(tester, state: {...playing, 'buffering': true});
    expect(find.text('Loading…'), findsOneWidget);
  });

  testWidgets('quality chip hidden when qualitySelection is false', (
    tester,
  ) async {
    await pump(tester, state: {...playing, 'qualitySelection': false});
    expect(find.byTooltip('Quality'), findsNothing);
    expect(find.byTooltip('Audio'), findsOneWidget);
    await pump(
      tester,
      state: {...playing, 'megaSkipEnabled': false, 'canSkipIntro': false},
    );
    expect(find.textContaining('Mega Skip'), findsNothing);
    expect(find.byTooltip('Mega Skip +90s'), findsNothing);
    expect(find.text('Skip Recap'), findsNothing);
    expect(find.byTooltip('Quality'), findsOneWidget);
  });

  testWidgets('navigation off while playing: tap pauses, swipes do nothing', (
    tester,
  ) async {
    final sent = await pump(
      tester,
      state: {...playing, 'navigationWhilePlaying': false},
    );
    final finger = await tester.startGesture(start(tester));
    await finger.moveBy(const Offset(80, 0));
    await finger.up();
    expect(sent, isEmpty);
    await tester.tapAt(start(tester));
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    expect(sent, ['toggle', 'forward']);
    expect(find.text('Tap to pause'), findsOneWidget);
  });

  testWidgets('error opens the full message', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: RemotePanel(
            connected: true,
            name: 'TV',
            status: '',
            remoteMode: false,
            state: browsing,
            error: 'The TV went to sleep.',
            onMode: (_) {},
            onManage: () {},
            onScan: () {},
            onSearch: () {},
            onShortcut: (_) {},
            command: (_, _) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('The TV went to sleep.'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  for (final size in [const Size(800, 400), const Size(320, 640)]) {
    testWidgets('fits ${size.width}x${size.height} in both states', (
      tester,
    ) async {
      for (final state in [browsing, playing]) {
        await pump(tester, state: state, size: size, keyboard: true);
        expect(tester.takeException(), isNull);
        expect(find.byType(GlassPad), findsOneWidget);
      }
    });
  }

  // Real route: app bar above, text scaled, error banner shown, both label modes.
  for (final (size, scale) in const [
    (Size(360, 640), 1.3),
    (Size(360, 640), 2.0),
    (Size(430, 932), 1.3),
    (Size(640, 360), 1.3),
    (Size(915, 412), 1.3),
    (Size(800, 1280), 1.3),
  ]) {
    testWidgets('no overflow at ${size.width}x${size.height}, text x$scale', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final labels in [true, false]) {
        if (RemotePrefs.instance.showLabels != labels) {
          await RemotePrefs.instance.setShowLabels(labels);
        }
        for (final state in [
          {...browsing, 'keyboardVersion': 1, 'keyboard': <String, dynamic>{}},
          playing,
          {...playing, 'buffering': true, 'navigationWhilePlaying': false},
        ]) {
          for (final connected in [true, false]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildAppTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    padding: const EdgeInsets.only(top: 24, bottom: 16),
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  appBar: AppBar(title: const Text('Remote')),
                  body: SafeArea(
                    top: false,
                    child: RemotePanel(
                      connected: connected,
                      name: 'Living room television with a long name',
                      status: 'Wi-Fi fallback · Bluetooth not connected',
                      remoteMode: false,
                      state: state,
                      error: 'The TV went to sleep while we were connecting.',
                      onMode: (_) {},
                      onManage: () {},
                      onScan: () {},
                      onSearch: () {},
                      onShortcut: (_) {},
                      onKeyboard: () {},
                      command: (_, _) {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: 'labels=$labels connected=$connected $state',
            );
            final padRect = tester.getRect(find.byType(GlassPad));
            // The status caption never draws over the play button or hints.
            final caption = find.descendant(
              of: find.byType(GlassPad),
              matching: find.text(connected ? 'Now playing' : 'x'),
            );
            if (caption.evaluate().isNotEmpty) {
              final c = tester.getRect(caption);
              for (final other in [
                find.byTooltip('Pause'),
                find.text('Swipe to move · tap to pause'),
                find.text('Tap to pause'),
              ]) {
                if (other.evaluate().isEmpty) continue;
                final o = tester.getRect(other.first);
                expect(o.bottom, lessThanOrEqualTo(c.top), reason: '$other');
              }
            }
            expect(
              padRect.height,
              greaterThanOrEqualTo(96),
              reason: 'pad too small: labels=$labels $state',
            );
          }
        }
      }
    });
  }

  testWidgets('long press dropped mid-press does not throw', (tester) async {
    var ok = 0;
    Widget padWith(VoidCallback? longPress) => MaterialApp(
      home: Scaffold(
        body: GlassPad(
          navigation: true,
          onStep: (_) {},
          onHold: (_) {},
          onRelease: () {},
          onTap: () {},
          onLongPress: longPress,
        ),
      ),
    );
    await tester.pumpWidget(padWith(() => ok++));
    final finger = await tester.startGesture(
      tester.getCenter(find.byType(GlassPad)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // Playback stops while the finger is still down.
    await tester.pumpWidget(padWith(null));
    await tester.pump(const Duration(milliseconds: 600));
    await finger.up();
    expect(tester.takeException(), isNull);
    expect(ok, 0);
  });
}
