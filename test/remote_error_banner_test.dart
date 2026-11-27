import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_theme.dart';
import 'package:watch_app/features/companion/remote_panel.dart';
import 'package:watch_app/features/companion/remote_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(RemotePrefs.instance.resetForTest);

  const longError =
      "Can't reach the TV. Check it's on the same Wi-Fi. The TV did not answer "
      'after several tries, so make sure the Zangetsu app is open on the TV '
      'and TV remote is turned on in its settings.';

  /// Pumps a phone-sized remote showing [longError]; counts Reconnect taps.
  Future<List<int>> pump(WidgetTester tester, {bool retry = true}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final retries = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: RemotePanel(
            connected: false,
            name: 'Living room',
            status: 'Waiting for your TV',
            remoteMode: false,
            state: const {},
            error: longError,
            onRetry: retry ? () => retries.add(1) : null,
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
    await tester.pump();
    return retries;
  }

  testWidgets('a long remote error wraps to two lines with an ellipsis', (
    tester,
  ) async {
    await pump(tester);
    final banner = find.byKey(const ValueKey('remote-error'));
    expect(banner, findsOneWidget);
    final text = tester.widget<Text>(
      find.descendant(of: banner, matching: find.text(longError)),
    );
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    final line = tester.getSize(
      find.descendant(of: banner, matching: find.text(longError)),
    );
    final style = text.style ?? const TextStyle();
    final lineHeight = (style.fontSize ?? 14) * (style.height ?? 1.2);
    // Taller than one line, but capped at two.
    expect(line.height, greaterThan(lineHeight * 1.2));
    expect(line.height, lessThanOrEqualTo(lineHeight * 2 + 4));
  });

  testWidgets('tapping the error opens the full text with Reconnect', (
    tester,
  ) async {
    final retries = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('remote-error')));
    await tester.pumpAndSettle();
    final full = find.byKey(const ValueKey('remote-error-full'));
    expect(full, findsOneWidget);
    final text = tester.widget<Text>(full);
    expect(text.data, longError);
    expect(text.maxLines, isNull);
    await tester.tap(find.text('Reconnect'));
    await tester.pumpAndSettle();
    expect(retries, [1]);
    expect(full, findsNothing);
  });

  testWidgets('the error sheet hides Reconnect when no retry is offered', (
    tester,
  ) async {
    await pump(tester, retry: false);
    await tester.tap(find.byKey(const ValueKey('remote-error')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-error-full')), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-error-full')), findsNothing);
  });
}
