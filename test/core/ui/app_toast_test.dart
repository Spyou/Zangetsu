import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/app_toast.dart';
import 'package:watch_app/core/ui/global_messenger.dart';

/// The app's toast is drawn into the Overlay, and [showAppToast] finds that
/// overlay with `Overlay.of(context)` — which searches a context's ANCESTORS.
///
/// A global callback (the Z Mode provider-fallback notice) has no screen
/// context, only a navigator key, and neither context a navigator key can hand
/// back works: `currentContext` sits above the overlay, and the overlay's own
/// context cannot find itself. Both threw "Overlay is null", once per session
/// across nine reports, so the warning that exists to stop a silent provider
/// switch never appeared. [showAppToastIn] takes the overlay itself instead.
void main() {
  Widget app() => MaterialApp(
    navigatorKey: rootNavigatorKey,
    home: const Scaffold(body: Text('home')),
  );

  testWidgets('shows the message, then takes it away again', (t) async {
    await t.pumpWidget(app());

    showAppToastIn(
      rootNavigatorKey.currentState!.overlay!,
      'Showing results from AniList',
    );
    await t.pump();
    expect(find.text('Showing results from AniList'), findsOneWidget);

    await t.pump(const Duration(seconds: 3));
    expect(find.text('Showing results from AniList'), findsNothing);
  });

  testWidgets('renders in the app font, not Flutter debug text', (t) async {
    // Without a Material ancestor an overlay entry draws text in monospace
    // with a yellow underline. It shipped looking exactly like that once.
    await t.pumpWidget(app());

    showAppToastIn(rootNavigatorKey.currentState!.overlay!, 'notice');
    await t.pump();

    expect(
      find.ancestor(of: find.text('notice'), matching: find.byType(Material)),
      findsAtLeastNWidgets(1),
    );
    final style = t.widget<Text>(find.text('notice')).style;
    expect(style?.decoration ?? TextDecoration.none, TextDecoration.none);

    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('never swallows a tap while it is up', (t) async {
    await t.pumpWidget(app());

    showAppToastIn(rootNavigatorKey.currentState!.overlay!, 'notice');
    await t.pump();

    expect(
      find.ancestor(of: find.text('notice'), matching: find.byType(IgnorePointer)),
      findsOneWidget,
    );
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('the ordinary screen toast still works', (t) async {
    // The twelve existing callers all pass a real screen context. This is the
    // path they take, unchanged by showAppToastIn existing.
    late BuildContext screen;
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              screen = c;
              return const Text('home');
            },
          ),
        ),
      ),
    );

    showAppToast(screen, 'from a screen');
    await t.pump();

    expect(find.text('from a screen'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('the contexts a navigator key offers cannot host it', (t) async {
    // Why showAppToastIn exists at all. If this ever starts passing, the
    // simpler `showAppToast(ctx, …)` is usable again from a global callback.
    await t.pumpWidget(app());

    expect(
      () => showAppToast(rootNavigatorKey.currentContext!, 'x'),
      throwsA(anything),
      reason: 'the key context is above the overlay',
    );
    expect(
      () => showAppToast(rootNavigatorKey.currentState!.overlay!.context, 'x'),
      throwsA(anything),
      reason: 'the overlay cannot find itself',
    );
  });
}
