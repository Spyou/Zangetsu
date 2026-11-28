import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_keyboard_bridge.dart';
import 'package:watch_app/core/tv/tv_text_field.dart';
import 'package:watch_app/features/home/tv_search_input_screen.dart';

const _companion = MethodChannel('zangetsu/companion');

TvKeyboardBridge get _bridge => TvKeyboardBridge.instance;

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

Future<Map<String, dynamic>> _send(
  WidgetTester tester,
  Map<String, dynamic> request,
) async {
  final reply = await _bridge.handle(request);
  await tester.pump();
  return reply;
}

Map<String, dynamic> _snap() => _bridge.snapshot()!;

void main() {
  setUp(() => _bridge.debugReset(isAndroid: () => false));
  tearDown(() => _bridge.debugReset());

  /// Lets the 3 s "typing from phone" hold expire so no timer is left pending.
  Future<void> settleTyping(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 4));

  testWidgets('no focused box gives a null snapshot and no focus change', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const Text('nothing to type')));
    _bridge.start();
    final before = FocusManager.instance.primaryFocus;
    expect(_bridge.snapshot(), isNull);
    final reply = await _send(tester, {'action': 'keyboardOpen'});
    expect(reply, {'ok': false, 'keyboard': null});
    final input = await _send(tester, {
      'action': 'keyboardInput',
      'field': 1,
      'text': 'x',
    });
    expect(input['ok'], isFalse);
    expect(input.containsKey('error'), isFalse);
    expect(FocusManager.instance.primaryFocus, same(before));
  });

  testWidgets('TvTextField: nav is manual, OK starts an auto edit session', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        TvTextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Email'),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
      ),
    );
    _bridge.start();
    await tester.pump();
    final nav = FocusManager.instance.primaryFocus;
    final selected = _snap();
    expect(selected['auto'], isFalse);
    expect(selected['hint'], 'Email');
    expect(selected['type'], 'email');
    expect(selected['action'], 'next');
    expect(selected['secure'], isFalse);

    // Opening and typing from the phone never moves TV focus.
    expect((await _send(tester, {'action': 'keyboardOpen'}))['ok'], isTrue);
    await _send(tester, {
      'action': 'keyboardInput',
      'field': selected['field'],
      'text': 'a@b.c',
    });
    expect(FocusManager.instance.primaryFocus, same(nav));
    expect(controller.text, 'a@b.c');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    final editing = _snap();
    expect(editing['auto'], isTrue);
    expect(editing['field'], isNot(selected['field']));
    expect(editing['text'], 'a@b.c');
    await settleTyping(tester);
  });

  testWidgets('input replaces text and fires onChanged; a stale field is '
      'rejected', (tester) async {
    final controller = TextEditingController(text: 'old');
    addTearDown(controller.dispose);
    final changes = <String>[];
    await tester.pumpWidget(
      _app(
        TvTextField(
          controller: controller,
          autofocus: true,
          maxLength: 5,
          onChanged: changes.add,
        ),
      ),
    );
    _bridge.start();
    await tester.pump();
    final field = _snap()['field'] as int;

    final stale = await _send(tester, {
      'action': 'keyboardInput',
      'field': field + 1,
      'text': 'nope',
    });
    expect(stale['ok'], isFalse);
    expect(stale.containsKey('error'), isFalse);
    expect(stale['keyboard']['field'], field);
    expect(controller.text, 'old');

    final ok = await _send(tester, {
      'action': 'keyboardInput',
      'field': field,
      'text': 'naruto',
    });
    expect(ok['ok'], isTrue);
    expect(controller.text, 'narut', reason: 'clipped to maxLength');
    expect(changes, ['narut']);
    expect(ok['keyboard']['text'], 'narut');
    expect(ok['keyboard']['maxLength'], 5);

    // Non-string text counts as empty.
    await _send(tester, {'action': 'keyboardInput', 'field': field, 'text': 7});
    expect(controller.text, '');
    await settleTyping(tester);
  });

  testWidgets('submit sets the text, fires onSubmitted and closes the IME', (
    tester,
  ) async {
    final submitted = <String>[];
    await tester.pumpWidget(
      _app(TvTextField(autofocus: true, onSubmitted: submitted.add)),
    );
    _bridge.start();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    final field = _snap()['field'];
    final reply = await _send(tester, {
      'action': 'keyboardSubmit',
      'field': field,
      'text': 'bleach',
    });
    expect(reply['ok'], isTrue);
    expect(submitted, ['bleach']);
    expect(_snap()['auto'], isFalse);
    expect(_snap()['text'], 'bleach');
  });

  testWidgets('secure fields never echo their text', (tester) async {
    final controller = TextEditingController(text: 'hunter2');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        TvTextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
      ),
    );
    _bridge.start();
    await tester.pump();
    final snap = _snap();
    expect(snap['secure'], isTrue);
    expect(snap['text'], '');
    expect(snap['hint'], 'Password');
    expect(snap['multiline'], isFalse);
  });

  testWidgets('a plain TextField is picked up generically', (tester) async {
    final changes = <String>[];
    final submitted = <String>[];
    await tester.pumpWidget(
      _app(
        TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Server URL'),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onChanged: changes.add,
          onSubmitted: submitted.add,
        ),
      ),
    );
    _bridge.start();
    await tester.pump();
    final snap = _snap();
    expect(snap['auto'], isTrue);
    expect(snap['hint'], 'Server URL');
    expect(snap['type'], 'url');
    expect(snap['action'], 'go');

    await _send(tester, {
      'action': 'keyboardInput',
      'field': snap['field'],
      'text': 'http://tv',
    });
    expect(changes.last, 'http://tv');
    expect(find.text('http://tv'), findsOneWidget);
    await _send(tester, {
      'action': 'keyboardSubmit',
      'field': snap['field'],
      'text': 'http://tv',
    });
    expect(submitted, ['http://tv']);
    await settleTyping(tester);
  });

  testWidgets('read-only text is ignored', (tester) async {
    await tester.pumpWidget(
      _app(const TextField(autofocus: true, readOnly: true)),
    );
    _bridge.start();
    await tester.pump();
    expect(_bridge.snapshot(), isNull);
  });

  testWidgets('New search keyboard is one search target', (tester) async {
    final queries = <String>[];
    final submitted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TvSearchInputScreen(
          initialQuery: '',
          compactStyle: true,
          inlineSearch: true,
          onQueryChanged: queries.add,
          onSearchSubmitted: submitted.add,
        ),
      ),
    );
    _bridge.start();
    await tester.pumpAndSettle();
    final snap = _snap();
    expect(snap['hint'], 'Search');
    expect(snap['action'], 'search');
    expect(snap['auto'], isTrue);
    expect(snap['maxLength'], 200);

    await _send(tester, {
      'action': 'keyboardInput',
      'field': snap['field'],
      'text': 'one piece',
    });
    expect(queries.last, 'one piece');
    expect(find.text('one piece'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tv-search-phone-typing')),
      findsOneWidget,
    );

    await _send(tester, {
      'action': 'keyboardSubmit',
      'field': snap['field'],
      'text': 'one piece',
    });
    expect(submitted, ['one piece']);
    await settleTyping(tester);
    expect(find.byKey(const ValueKey('tv-search-phone-typing')), findsNothing);
  });

  testWidgets('dismiss keeps focus and stops auto-open for that field', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const TvTextField(autofocus: true)));
    _bridge.start();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    final field = _snap()['field'];
    expect(_snap()['auto'], isTrue);

    final reply = await _send(tester, {
      'action': 'keyboardDismiss',
      'field': field,
    });
    expect(reply['ok'], isTrue);
    // The TV returns from its edit node to its own nav node, still selected.
    expect(_snap()['field'], field);
    expect(_snap()['auto'], isFalse);

    // Editing again starts a new session that may auto-open.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(_snap()['auto'], isTrue);
    expect(_snap()['field'], isNot(field));
  });

  testWidgets('Android pushes the snapshot JSON to the native receiver', (
    tester,
  ) async {
    final pushes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_companion, (
      call,
    ) async {
      if (call.method == 'receiverKeyboard') pushes.add(call.arguments);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _companion,
        null,
      ),
    );
    _bridge.debugReset(isAndroid: () => true);
    await tester.pumpWidget(
      _app(
        const TvTextField(
          autofocus: true,
          decoration: InputDecoration(hintText: 'Name'),
        ),
      ),
    );
    _bridge.start();
    await tester.pump(const Duration(milliseconds: 60));
    expect(pushes, isNotEmpty);
    final json = jsonDecode(pushes.last! as String) as Map<String, dynamic>;
    expect(json['hint'], 'Name');
    expect(json['auto'], isFalse);

    // Unchanged state is not pushed again.
    final count = pushes.length;
    _bridge.changed();
    await tester.pump(const Duration(milliseconds: 60));
    expect(pushes.length, count);

    // Leaving the screen pushes null.
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump(const Duration(milliseconds: 60));
    expect(pushes.last, isNull);
  });
}
