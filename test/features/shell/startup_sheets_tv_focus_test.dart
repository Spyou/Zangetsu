import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/announce/announcement.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/announce/announcement_sheet.dart';
import 'package:watch_app/features/community/community_sheet.dart';

/// The community and announcement sheets open over Home at launch. On TV,
/// Home mounting autofocused rows late (or anything below grabbing focus)
/// must not leave "Maybe later" / "Got it" unreachable.
void main() {
  late ValueNotifier<bool> showLate;
  late FocusNode homeNode;
  late FocusNode lateNode;
  late BuildContext homeContext;

  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
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

  bool focusInSheet() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && ctx.findAncestorWidgetOfExactType<BottomSheet>() != null;
  }

  testWidgets('community sheet keeps D-pad focus and reaches Maybe later', (
    tester,
  ) async {
    await pumpHome(tester);
    showCommunitySheet(homeContext);
    await tester.pumpAndSettle();
    expect(focusInSheet(), isTrue);

    showLate.value = true;
    await tester.pumpAndSettle();
    expect(lateNode.hasFocus, isFalse);
    expect(focusInSheet(), isTrue);

    homeNode.requestFocus();
    await tester.pumpAndSettle();
    expect(focusInSheet(), isTrue);

    // Telegram -> Discord -> Maybe later, one stop each.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusInSheet(), isTrue);
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
        of: find.byElementPredicate((e) => identical(e, focused)),
        matching: find.text('Maybe later'),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('announcement sheet keeps D-pad focus on Got it', (
    tester,
  ) async {
    await pumpHome(tester);
    showAnnouncementSheet(
      homeContext,
      const Announcement(id: 'a1', title: 'Hello', body: 'Body'),
    );
    await tester.pumpAndSettle();
    expect(focusInSheet(), isTrue);

    showLate.value = true;
    await tester.pumpAndSettle();
    expect(lateNode.hasFocus, isFalse);

    homeNode.requestFocus();
    await tester.pumpAndSettle();
    expect(focusInSheet(), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });
}
