import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';
import 'package:watch_app/features/aniyomi/aniyomi_filter_sheet.dart';

/// A filter list long enough that the sheet wants more room than a
/// keyboard-reduced viewport leaves it — the condition that used to crush the
/// sheet down to its header.
List<AniyomiFilter> _manyFilters() => [
  AniyomiSelect(
    name: 'Sort order',
    values: const ['Default', 'Latest', 'Score', 'Release Date'],
    state: 0,
  ),
  AniyomiGroup(
    name: 'Genre',
    children: [
      for (final g in const [
        'Action',
        'Adventure',
        'Cars',
        'Comedy',
        'Dementia',
        'Demons',
        'Drama',
        'Ecchi',
        'Fantasy',
        'Game',
      ])
        AniyomiCheckBox(name: g, state: false),
    ],
  ),
  AniyomiSelect(
    name: 'Year',
    values: const ['Any', '2024', '2023', '2022'],
    state: 0,
  ),
  AniyomiSelect(name: 'Type', values: const ['Any', 'TV', 'Movie'], state: 0),
  AniyomiSelect(
    name: 'Status',
    values: const ['Any', 'Airing', 'Finished'],
    state: 0,
  ),
];

/// Pumps the sheet inside a viewport whose bottom inset simulates an open
/// keyboard of [keyboardHeight] logical pixels.
Future<void> _pumpSheet(WidgetTester tester, double keyboardHeight) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  showAniyomiFilterSheet(context, _manyFilters()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          viewInsets: EdgeInsets.only(bottom: keyboardHeight),
        ),
        child: child!,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('Aniyomi filter sheet with the keyboard open', () {
    testWidgets('lays out without overflowing', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // ~340dp of keyboard — a realistic phone IME.
      await _pumpSheet(tester, 340);

      expect(
        tester.takeException(),
        isNull,
        reason: 'sizing against the full screen height overflows the sheet '
            'once the keyboard takes part of the viewport',
      );
    });

    testWidgets('keeps Apply and Cancel reachable', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await _pumpSheet(tester, 340);

      // The action row is the thing that got pushed off-screen: the sheet still
      // claimed 85% of the FULL height, so its bottom sat under the keyboard.
      expect(find.text('Apply'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      final apply = tester.getRect(find.text('Apply'));
      final visibleBottom = tester.view.physicalSize.height /
              tester.view.devicePixelRatio -
          340;
      expect(
        apply.bottom,
        lessThanOrEqualTo(visibleBottom),
        reason: 'Apply must sit above the keyboard, not behind it',
      );
    });

    testWidgets('still renders normally with no keyboard', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await _pumpSheet(tester, 0);

      expect(tester.takeException(), isNull);
      expect(find.text('Source filters'), findsOneWidget);
      expect(find.text('Apply'), findsOneWidget);
      expect(find.text('Sort order'), findsOneWidget);
    });
  });
}
