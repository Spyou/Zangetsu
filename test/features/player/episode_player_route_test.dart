import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/episode_player_route.dart';

void main() {
  testWidgets('episode starts building during the slide and slides back down', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    var builds = 0;
    const pageKey = ValueKey('episode');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Text('Detail')),
      ),
    );
    final route = EpisodePlayerRoute(
      builder: (_) {
        builds++;
        return const Scaffold(key: pageKey, body: Text('Episode'));
      },
    );
    nav.currentState!.push(route);
    await tester.pump();
    expect(builds, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 175));
    final middle = tester.getTopLeft(find.byKey(pageKey)).dy;
    expect(middle, greaterThan(0));
    expect(middle, lessThan(tester.view.physicalSize.height));
    expect(
      find.ancestor(
        of: find.byKey(pageKey),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 175));
    expect(tester.getTopLeft(find.byKey(pageKey)).dy, closeTo(0, 0.01));
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175));
    expect(tester.getTopLeft(find.byKey(pageKey)).dy, greaterThan(0));
    await tester.pumpAndSettle();
    expect(find.byKey(pageKey), findsNothing);
    expect(find.text('Detail'), findsOneWidget);
  });

  testWidgets('reduced motion shows the player without sliding', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    const pageKey = ValueKey('episode');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: Text('Detail')),
      ),
    );
    nav.currentState!.push(
      EpisodePlayerRoute(builder: (_) => const Scaffold(key: pageKey)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.getTopLeft(find.byKey(pageKey)).dy, 0);
    await tester.pumpAndSettle();
  });
  testWidgets('iOS keeps its standard swipe-back transition', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: const Scaffold(body: Text('Detail')),
      ),
    );
    nav.currentState!.push(
      EpisodePlayerRoute(builder: (_) => const Scaffold(body: Text('Episode'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoPageTransition), findsWidgets);
    await tester.dragFrom(const Offset(1, 300), const Offset(700, 0));
    await tester.pumpAndSettle();
    expect(find.text('Episode'), findsNothing);
    expect(find.text('Detail'), findsOneWidget);
  });
}
