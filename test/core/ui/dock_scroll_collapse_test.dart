import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/dock_visibility.dart';

/// A scroll of [delta] pixels at [pixels] on a vertical (or [axis]) view.
/// Positive [delta] is scrolling DOWN — the offset grows.
ScrollUpdateNotification _scroll(
  BuildContext context,
  double delta, {
  double pixels = 500,
  Axis axis = Axis.vertical,
}) => ScrollUpdateNotification(
  metrics: FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 4000,
    pixels: pixels,
    viewportDimension: 800,
    axisDirection: axis == Axis.vertical
        ? AxisDirection.down
        : AxisDirection.right,
    devicePixelRatio: 2,
  ),
  context: context,
  scrollDelta: delta,
);

void main() {
  /// Pumps a throwaway widget purely to get a real [BuildContext] — the
  /// notification constructor requires one, nothing under test reads it.
  Future<BuildContext> boot(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    DockScrollCollapse.reset();
    return tester.element(find.byType(SizedBox));
  }

  void drag(
    BuildContext c,
    double delta, {
    int n = 1,
    double pixels = 500,
    Axis axis = Axis.vertical,
  }) {
    for (var i = 0; i < n; i++) {
      DockScrollCollapse.onNotification(
        _scroll(c, delta, pixels: pixels, axis: axis),
      );
    }
  }

  testWidgets('scrolling down past the threshold collapses it', (t) async {
    final c = await boot(t);
    drag(c, 20, n: 2); // 40 — under 60, nothing yet
    expect(dockCollapsedByScroll.value, isFalse);
    drag(c, 30); // 70 — over
    expect(dockCollapsedByScroll.value, isTrue);
  });

  testWidgets('scrolling back up past the threshold restores it', (t) async {
    final c = await boot(t);
    drag(c, 70);
    expect(dockCollapsedByScroll.value, isTrue);
    drag(c, -70);
    expect(dockCollapsedByScroll.value, isFalse);
  });

  testWidgets('a jittery thumb never flips it', (t) async {
    final c = await boot(t);
    // Far past 60px of travel in total, but never 60 in ONE direction.
    for (var i = 0; i < 12; i++) {
      drag(c, 40);
      drag(c, -40);
    }
    expect(dockCollapsedByScroll.value, isFalse);
  });

  testWidgets('a direction change restarts the count', (t) async {
    final c = await boot(t);
    drag(c, 50); // 50 down — not enough
    drag(c, -20); // flip: the 50 is discarded, not netted down to 30
    drag(c, -50); // 70 up in total, but it was never collapsed
    expect(dockCollapsedByScroll.value, isFalse);
    // Going down now needs a full 60 of its own.
    drag(c, 50);
    expect(dockCollapsedByScroll.value, isFalse);
    drag(c, 20);
    expect(dockCollapsedByScroll.value, isTrue);
  });

  testWidgets('a horizontal rail is ignored — only the page drives it', (
    t,
  ) async {
    final c = await boot(t);
    drag(c, 60, n: 10, axis: Axis.horizontal);
    expect(dockCollapsedByScroll.value, isFalse);
  });

  testWidgets('coming back near the top always restores it', (t) async {
    final c = await boot(t);
    drag(c, 70);
    expect(dockCollapsedByScroll.value, isTrue);
    // One small scroll while already at the top — not 60px of anything.
    drag(c, 1, pixels: 4);
    expect(dockCollapsedByScroll.value, isFalse);
  });

  testWidgets('reset puts it back whole', (t) async {
    final c = await boot(t);
    drag(c, 70);
    expect(dockCollapsedByScroll.value, isTrue);
    DockScrollCollapse.reset();
    expect(dockCollapsedByScroll.value, isFalse);
  });

  testWidgets('it observes the scroll, it never consumes it', (t) async {
    final c = await boot(t);
    expect(DockScrollCollapse.onNotification(_scroll(c, 70)), isFalse);
    expect(DockScrollCollapse.onNotification(_scroll(c, -70)), isFalse);
    expect(
      DockScrollCollapse.onNotification(
        _scroll(c, 70, axis: Axis.horizontal),
      ),
      isFalse,
    );
  });

  testWidgets('a real list, wired the way the shell wires it', (tester) async {
    DockScrollCollapse.reset();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: NotificationListener<ScrollNotification>(
          onNotification: DockScrollCollapse.onNotification,
          child: ListView.builder(
            itemCount: 200,
            itemBuilder: (_, i) => SizedBox(height: 80, child: Text('$i')),
          ),
        ),
      ),
    );
    expect(dockCollapsedByScroll.value, isFalse);

    // Drag the content UP — that is scrolling down the page.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(
      dockCollapsedByScroll.value,
      isTrue,
      reason: 'scrolling down should collapse the dock',
    );

    // Back down — scrolling up the page.
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    expect(
      dockCollapsedByScroll.value,
      isFalse,
      reason: 'scrolling up should restore it',
    );
    await tester.pumpAndSettle();
  });
}
