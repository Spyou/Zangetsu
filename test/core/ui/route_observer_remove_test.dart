import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/route_observer.dart';

class _Aware with RouteAware {
  final events = <String>[];
  @override
  void didPushNext() => events.add('covered');
  @override
  void didPopNext() => events.add('uncovered');
}

void main() {
  testWidgets('removing the top route uncovers the one below, like a pop', (
    tester,
  ) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [appRouteObserver],
        home: const SizedBox(),
      ),
    );
    final aware = _Aware();
    final home = ModalRoute.of(tester.element(find.byType(SizedBox)))!;
    appRouteObserver.subscribe(aware, home as PageRoute<dynamic>);
    addTearDown(() => appRouteObserver.unsubscribe(aware));

    final top = MaterialPageRoute<void>(builder: (_) => const Text('top'));
    navKey.currentState!.push(top);
    await tester.pumpAndSettle();
    expect(aware.events, ['covered']);

    // How the player docks: removed from the stack, not popped.
    navKey.currentState!.removeRoute(top);
    await tester.pumpAndSettle();
    expect(aware.events, ['covered', 'uncovered']);
  });
}
