import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/home_screen.dart';
import 'package:watch_app/features/home/search_screen.dart';

/// Search left the dock (task 17) — this header icon, beside
/// [HomeBrowseSourcesAction], is the primary way in now. Unlike the sources
/// icon it isn't gated on Z Mode: it must show either way, since Search
/// itself already switches between the metadata catalogue and the active
/// source depending on the toggle.
///
/// Records the push instead of letting it build — see
/// reading_detail_routing_test.dart's `_RecordingNavigatorObserver` doc:
/// `didPush` fires synchronously inside `Navigator.push`, before any
/// rebuild, so checking it right after `tester.tap()` (no follow-up
/// `pump()`) never actually mounts `SearchScreen`'s State, which needs a
/// dozen registered singletons that are beside the point here.
class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_search_action');
    Hive.init(tempDir.path);
    await ZModePrefs.init();
  });

  tearDown(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<_RecordingNavigatorObserver> pumpAction(WidgetTester tester) async {
    final observer = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: const Scaffold(body: HomeSearchAction()),
      ),
    );
    return observer;
  }

  testWidgets('Z Mode off: the search icon shows', (tester) async {
    expect(ZModePrefs.enabled, isFalse);
    await pumpAction(tester);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });

  testWidgets('Z Mode on: the search icon still shows', (tester) async {
    // A real Hive write never drains under the pump-driven testWidgets
    // binding without runAsync — same gotcha as home_browse_sources_action's.
    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    await pumpAction(tester);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });

  testWidgets('tapping it pushes SearchScreen', (tester) async {
    final observer = await pumpAction(tester);
    // MaterialApp's own initial route already counts as one push.
    final before = observer.pushed.length;

    // No pump() after this tap on purpose — see _RecordingNavigatorObserver.
    await tester.tap(find.byIcon(Icons.search_rounded));
    expect(observer.pushed.length, before + 1);

    final pushedRoute = observer.pushed.last as MaterialPageRoute;
    final pushedWidget = pushedRoute.builder(
      tester.element(find.byType(HomeSearchAction)),
    );
    expect(pushedWidget, isA<SearchScreen>());
  });
}
