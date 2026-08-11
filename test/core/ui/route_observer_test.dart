import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/route_observer.dart';

/// Mirrors exactly how the detail hero trailer uses [appRouteObserver]: subscribe
/// in didChangeDependencies, pause when another screen is pushed on top
/// (didPushNext), resume when it's popped back off (didPopNext). If this passes,
/// the trailer's pause/resume triggers fire at the right moments — which is the
/// whole fix. (Uses a plain flag stand-in for the media_kit Player so the test
/// stays deterministic and headless.)
class _TrailerProbe extends StatefulWidget {
  const _TrailerProbe({required this.onPause, required this.onResume});
  final VoidCallback onPause;
  final VoidCallback onResume;

  @override
  State<_TrailerProbe> createState() => _TrailerProbeState();
}

class _TrailerProbeState extends State<_TrailerProbe> with RouteAware {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => widget.onPause();

  @override
  void didPopNext() => widget.onResume();

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets(
      'trailer pauses when a screen covers it and resumes when it returns',
      (tester) async {
    var pauses = 0;
    var resumes = 0;

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [appRouteObserver],
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                _TrailerProbe(
                  onPause: () => pauses++,
                  onResume: () => resumes++,
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('player')),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Nothing on top yet.
    expect(pauses, 0);
    expect(resumes, 0);

    // Push a screen over the detail page → trailer should pause.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(pauses, 1, reason: 'covering the page must pause the trailer');
    expect(resumes, 0);

    // Pop it → detail page is on top again → trailer should resume.
    Navigator.of(tester.element(find.text('player'))).pop();
    await tester.pumpAndSettle();
    expect(pauses, 1);
    expect(resumes, 1, reason: 'returning to the page must resume the trailer');
  });
}
