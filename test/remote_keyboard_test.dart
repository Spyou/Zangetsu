import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_theme.dart';
import 'package:watch_app/features/companion/remote_keyboard.dart';
import 'package:watch_app/features/companion/remote_panel.dart';
import 'package:watch_app/features/companion/remote_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final session = RemoteSession.instance;
  late Map<String, dynamic> tv;
  late List<Map<String, dynamic>> sent;
  var inFlight = 0, maxInFlight = 0;

  Map<String, dynamic> field({
    int id = 7,
    String text = '',
    bool auto = true,
    bool secure = false,
    String hint = 'Search',
  }) => {
    'field': id,
    'text': text,
    'hint': hint,
    'secure': secure,
    'action': 'search',
    'type': 'text',
    'multiline': false,
    'maxLength': null,
    'auto': auto,
  };

  setUp(() {
    tv = {'active': false, 'appForeground': true};
    sent = [];
    inFlight = maxInFlight = 0;
    session
      ..connected = true
      ..keyboardSupported = false;
    session.keyboard.value = null;
    session.playback.value = {};
    RemoteKeyboardSheet.lastDismissedField = null;
    RemoteKeyboardSheet.isOpen = false;
    RemoteKeyboardHost.visibleHosts = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RemoteSession.channel, (call) async {
      if (call.method != 'command') return null;
      final request = jsonDecode(call.arguments as String) as Map;
      final action = request['action'] as String;
      sent.add(Map<String, dynamic>.from(request));
      if (action == 'state') return jsonEncode(tv);
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      inFlight--;
      final keyboard = tv['keyboard'] as Map<String, dynamic>?;
      final ok = keyboard != null && request['field'] == keyboard['field'];
      if (ok && action == 'keyboardInput') keyboard['text'] = request['text'];
      return jsonEncode({'ok': ok, 'keyboard': keyboard});
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(RemoteSession.channel, null),
    );
  });

  Iterable<Map<String, dynamic>> actions(String action) =>
      sent.where((request) => request['action'] == action);

  Future<void> poll(WidgetTester tester) async {
    unawaited(session.command('state'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpRemote(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    session.resetCommandQueue();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: session.playback,
            builder: (context, state, _) => RemoteKeyboardHost(
              autoOpen: true,
              child: RemotePanel(
                connected: true,
                name: 'Living room',
                status: 'Wi-Fi',
                remoteMode: false,
                state: state,
                onMode: (_) {},
                onManage: () {},
                onScan: () {},
                onSearch: () {},
                onShortcut: (_) {},
                command: (_, _) {},
                onKeyboard: () =>
                    RemoteKeyboardSheet.show(context, manual: true),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  final sheet = find.byType(RemoteKeyboardSheet);
  final keyboardButton = find.text('Keyboard');

  testWidgets('an older TV shows no keyboard and gets no keyboard actions', (
    tester,
  ) async {
    tv['keyboard'] = field();
    await pumpRemote(tester);
    await poll(tester);
    expect(session.keyboardSupported, isFalse);
    expect(session.keyboard.value, isNull);
    expect(keyboardButton, findsNothing);
    expect(sheet, findsNothing);
    expect(await session.keyboardCommand('keyboardOpen'), isEmpty);
    expect(actions('keyboardOpen'), isEmpty);
    await finish(tester);
  });

  testWidgets('a selected TV box shows the button with a dot, no sheet', (
    tester,
  ) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field(auto: false, text: 'nar');
    await pumpRemote(tester);
    await poll(tester);
    expect(keyboardButton, findsOneWidget);
    final badge = tester.widget<Badge>(
      find.ancestor(
        of: find.byIcon(Icons.keyboard_alt_outlined),
        matching: find.byType(Badge),
      ),
    );
    expect(badge.isLabelVisible, isTrue);
    expect(sheet, findsNothing);
    // Manual open attaches straight onto the selected box.
    await tester.tap(keyboardButton);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    final input = find.byKey(const ValueKey('remoteKeyboardField'));
    expect(tester.widget<TextField>(input).controller!.text, 'nar');
    expect(actions('keyboardOpen'), isEmpty);
    await finish(tester);
  });

  testWidgets(
    'no selected box: button has no dot and manual open asks the TV',
    (tester) async {
      tv['keyboardVersion'] = 1;
      await pumpRemote(tester);
      await poll(tester);
      final badge = tester.widget<Badge>(
        find.ancestor(
          of: find.byIcon(Icons.keyboard_alt_outlined),
          matching: find.byType(Badge),
        ),
      );
      expect(badge.isLabelVisible, isFalse);
      await tester.tap(keyboardButton);
      await tester.pumpAndSettle();
      expect(find.text('Select a text box on the TV'), findsOneWidget);
      expect(actions('keyboardOpen'), hasLength(1));
      // The sheet attaches once the TV reports a box.
      tv['keyboard'] = field(auto: false);
      await poll(tester);
      expect(find.text('Select a text box on the TV'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets('TV editing auto-opens and typing is coalesced', (tester) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field();
    await pumpRemote(tester);
    await poll(tester);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    expect(find.text('Typing on ${session.name}'), findsOneWidget);
    final input = find.byKey(const ValueKey('remoteKeyboardField'));
    await tester.enterText(input, 'a');
    await tester.pump(const Duration(milliseconds: 70));
    await tester.enterText(input, 'ab');
    await tester.pump(const Duration(milliseconds: 10));
    await tester.enterText(input, 'abc');
    await tester.pump(const Duration(milliseconds: 300));
    final inputs = actions('keyboardInput').toList();
    expect(inputs, isNotEmpty);
    expect(inputs.length, lessThan(3));
    expect(inputs.every((request) => request['field'] == 7), isTrue);
    expect(inputs.last['text'], 'abc');
    expect(maxInFlight, 1);
    expect(find.text('On TV: abc'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('submit sends keyboardSubmit and closes the sheet', (
    tester,
  ) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field();
    await pumpRemote(tester);
    await poll(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('remoteKeyboardField')),
      'naruto',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    final submit = actions('keyboardSubmit').single;
    expect(submit['field'], 7);
    expect(submit['text'], 'naruto');
    expect(actions('keyboardDismiss'), isEmpty);
    // The same field does not pop the sheet again.
    await poll(tester);
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    await finish(tester);
  });

  testWidgets('the TV leaving the box closes the sheet without dismiss', (
    tester,
  ) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field();
    await pumpRemote(tester);
    await poll(tester);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    tv['keyboard'] = null;
    await poll(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(actions('keyboardDismiss'), isEmpty);
    await finish(tester);
  });

  testWidgets('a user close dismisses once and does not reopen', (
    tester,
  ) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field();
    await pumpRemote(tester);
    await poll(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close keyboard'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(actions('keyboardDismiss').single['field'], 7);
    await poll(tester);
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    // A new edit session (new field id) opens it again.
    tv['keyboard'] = field(id: 8);
    await poll(tester);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    await finish(tester);
  });

  testWidgets('closing right after typing still sends the text first', (
    tester,
  ) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field();
    await pumpRemote(tester);
    await poll(tester);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('remoteKeyboardField'));
    await tester.enterText(input, 'hi');
    // Closed inside the input debounce: nothing has been sent yet.
    await tester.tap(find.byTooltip('Close keyboard'));
    await tester.pumpAndSettle();
    final order = sent
        .map((request) => request['action'])
        .where((action) => action != 'state')
        .toList();
    expect(order, ['keyboardInput', 'keyboardDismiss']);
    expect(actions('keyboardInput').single['text'], 'hi');
    await finish(tester);
  });

  testWidgets('four navigation buttons fit a 320 wide phone', (tester) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field(auto: false);
    await pumpRemote(tester, size: const Size(320, 640));
    await poll(tester);
    expect(keyboardButton, findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('a secure box is obscured and never mirrored', (tester) async {
    tv
      ..['keyboardVersion'] = 1
      ..['keyboard'] = field(secure: true, hint: 'Password');
    await pumpRemote(tester);
    await poll(tester);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('remoteKeyboardField'));
    expect(tester.widget<TextField>(input).obscureText, isTrue);
    await tester.enterText(input, 'hunter2');
    await tester.pump(const Duration(milliseconds: 300));
    expect(actions('keyboardInput').last['text'], 'hunter2');
    expect(find.textContaining('On TV:'), findsNothing);
    // Only the obscured input holds the password; no label repeats it.
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').contains('hunter2'),
      ),
      findsNothing,
    );
    await finish(tester);
  });
}
