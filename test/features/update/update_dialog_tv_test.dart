import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/update/update_service.dart';
import 'package:watch_app/features/update/update_dialog.dart';

class _FakeUpdateService extends UpdateService {
  final skipped = <String>[];

  final download = Completer<File>();

  @override
  Future<void> skipVersion(String version) async => skipped.add(version);

  @override
  Future<File> downloadApk(
    String url, {
    int expectedSize = 0,
    void Function(double progress)? onProgress,
  }) => download.future;
}

const _info = UpdateInfo(
  version: '9.9.9',
  notes: '',
  apkUrl: 'https://example.invalid/app.apk',
  assetName: 'app.apk',
  apkSize: 0,
);

/// The text inside the widget that holds primary focus, or null.
String? _focusedLabel() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  String? label;
  void visit(Element e) {
    if (label != null) return;
    final w = e.widget;
    if (w is Text && w.data != null) {
      label = w.data;
      return;
    }
    e.visitChildren(visit);
  }

  (ctx as Element).visitChildren(visit);
  return label;
}

bool _focusInDialog() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.findAncestorWidgetOfExactType<Dialog>() != null;
}

void main() {
  late _FakeUpdateService service;
  late ValueNotifier<bool> showLate;
  late FocusNode homeNode;
  late FocusNode lateNode;
  late BuildContext homeContext;

  setUp(() {
    service = _FakeUpdateService();
    showLate = ValueNotifier(false);
    homeNode = FocusNode(debugLabel: 'home-play');
    lateNode = FocusNode(debugLabel: 'home-late-row');
  });

  tearDown(() async {
    showLate.dispose();
    homeNode.dispose();
    lateNode.dispose();
    await sl.reset();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            homeContext = context;
            return Scaffold(
              body: Column(
                children: [
                  TvFocusable(
                    focusNode: homeNode,
                    onTap: () {},
                    child: const Text('Play'),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: showLate,
                    builder: (_, show, _) => show
                        ? TvFocusable(
                            focusNode: lateNode,
                            autofocus: true,
                            onTap: () {},
                            child: const Text('Row'),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    showUpdateDialog(homeContext, info: _info, service: service);
    await tester.pumpAndSettle();
  }

  group('on TV', () {
    setUp(() => sl.registerSingleton<AppMode>(const AppMode(isTv: true)));

    testWidgets('Later has D-pad focus when the dialog opens', (tester) async {
      await pumpHome(tester);
      await openDialog(tester);
      expect(_focusedLabel(), 'Later');
      expect(_focusInDialog(), isTrue);
    });

    testWidgets('arrows reach Skip and never leave the dialog', (
      tester,
    ) async {
      await pumpHome(tester);
      await openDialog(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(_focusedLabel(), 'Skip');

      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(_focusInDialog(), isTrue, reason: 'after $key');
        expect(homeNode.hasFocus, isFalse);
      }
    });

    testWidgets('OK on Skip skips the version and closes', (tester) async {
      await pumpHome(tester);
      await openDialog(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(_focusedLabel(), 'Skip');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(service.skipped, ['9.9.9']);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('OK on Later closes without skipping', (tester) async {
      await pumpHome(tester);
      await openDialog(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(service.skipped, isEmpty);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('a late Home autofocus does not take focus from the dialog', (
      tester,
    ) async {
      await pumpHome(tester);
      await openDialog(tester);

      showLate.value = true; // Home rows arrive while the prompt is up.
      await tester.pumpAndSettle();
      expect(_focusedLabel(), 'Later');
      expect(lateNode.hasFocus, isFalse);
    });

    testWidgets('focus taken by the screen below is pulled back', (
      tester,
    ) async {
      await pumpHome(tester);
      await openDialog(tester);

      homeNode.requestFocus();
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_focusInDialog(), isTrue);
      expect(_focusedLabel(), 'Later');
    });

    testWidgets('focus lost mid-download falls through to Update', (
      tester,
    ) async {
      await pumpHome(tester);
      await openDialog(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focusedLabel(), 'Update');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump();
      expect(find.text('Later'), findsNothing); // Skip / Later hide while busy

      // Later's node is detached now; the claim must skip it, not stall.
      homeNode.requestFocus();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_focusInDialog(), isTrue);
      expect(_focusedLabel(), 'Update');
    });

    testWidgets('join-beta confirm focuses Not now on TV', (tester) async {
      await pumpHome(tester);
      bool? joined;
      confirmJoinBeta(homeContext).then((v) => joined = v);
      await tester.pumpAndSettle();
      expect(_focusedLabel(), 'Not now');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(joined, isFalse);
    });
  });

  group('on phone', () {
    setUp(() => sl.registerSingleton<AppMode>(const AppMode(isTv: false)));

    testWidgets('keeps the plain Material buttons', (tester) async {
      await pumpHome(tester);
      await openDialog(tester);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TvFocusable),
        ),
        findsNothing,
      );
      expect(find.widgetWithText(TextButton, 'Skip'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Later'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(service.skipped, ['9.9.9']);
    });
  });
}
