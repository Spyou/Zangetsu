import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/tv/tv_alert_dialog.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';

/// Mirrors Settings-on-TV: a nested navigator sitting inside the shell
/// content [FocusScopeNode]. Without hoisting the dialog to the root
/// navigator, OK never receives D-pad focus — the tile that opened the
/// popup keeps it, and arrows walk the screen underneath.
void main() {
  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
  });

  tearDown(sl.reset);

  testWidgets(
    'D-pad focus moves to the dialog OK button, not the tiles underneath',
    (tester) async {
      final contentScope = FocusScopeNode(debugLabel: 'tv-content-scope');
      addTearDown(contentScope.dispose);

      var otherTileActivated = false;
      var okActivated = false;

      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Focus(
            focusNode: contentScope,
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: Column(
                    children: [
                      TvFocusable(
                        autofocus: true,
                        onTap: () {
                          showTvAlertDialog<void>(
                            context,
                            title: 'Restore complete',
                            body: const Text('Library restored'),
                            actions: [
                              TvAlertAction(
                                label: 'OK',
                                primary: true,
                                autofocus: true,
                                onTap: () {
                                  okActivated = true;
                                  Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).pop();
                                },
                              ),
                            ],
                          );
                        },
                        child: const Text('Restore from cloud'),
                      ),
                      TvFocusable(
                        onTap: () => otherTileActivated = true,
                        child: const Text('Save to a file'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open the dialog the way a remote does: OK on the focused tile.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('Restore complete'), findsOneWidget);

      // Settings-on-TV often re-seeds the content scope after a rebuild
      // (busy overlay dismissed). The dialog must reclaim leaf focus.
      contentScope.traversalDescendants
          .where((n) => n.canRequestFocus)
          .firstOrNull
          ?.requestFocus();
      await tester.pump();
      await tester.pump();

      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'tv-alert-OK',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(otherTileActivated, isFalse);
      expect(okActivated, isTrue);
      expect(find.text('Restore complete'), findsNothing);
    },
  );

  testWidgets(
    'dialog actions draw their own outline and skip TvFocusable shading',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  showTvAlertDialog<void>(
                    context,
                    title: 'Restore complete',
                    body: const Text('Library restored'),
                    actions: const [
                      TvAlertAction(label: 'Cancel', onTap: _noop),
                      TvAlertAction(
                        label: 'OK',
                        primary: true,
                        autofocus: true,
                        onTap: _noop,
                      ),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final actions = tester
          .widgetList<TvFocusable>(find.byType(TvFocusable))
          .where((w) => w.semanticLabel == 'Cancel' || w.semanticLabel == 'OK')
          .toList();
      expect(actions, hasLength(2));
      for (final action in actions) {
        expect(action.variant, TvFocusVariant.none);
      }
    },
  );
}

void _noop() {}
