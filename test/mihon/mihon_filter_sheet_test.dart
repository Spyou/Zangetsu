// Mihon twin of test/aniyomi/aniyomi_filter_sheet_test.dart — same UX, same
// control types, over the separate MihonFilter model. Covers every variant
// the sheet renders (select, text, checkbox, tristate, sort, group) plus
// Apply/Cancel and the selection-JSON round trip via MihonFilters.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_filters.dart';
import 'package:watch_app/features/mihon/mihon_filter_sheet.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<MihonFilter> _makeFilters() => [
      MihonSelect(name: 'Language', values: ['All', 'English', 'Japanese'], state: 0),
      MihonText(name: 'Author', state: ''),
      MihonTriState(name: 'Completed', state: 0),
      MihonCheckBox(name: 'NSFW', state: false),
      MihonSort(
        name: 'Sort By',
        values: ['Popularity', 'Latest'],
        index: null,
        ascending: true,
      ),
      MihonGroup(
        name: 'Genres',
        children: [MihonCheckBox(name: 'Action', state: false)],
      ),
    ];

class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.filters});
  final List<MihonFilter> filters;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  List<MihonFilter>? result;
  bool resultReady = false;

  Future<void> _open() async {
    final r = await showMihonFilterSheet(context, widget.filters);
    if (mounted) setState(() { result = r; resultReady = true; });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton(onPressed: _open, child: const Text('Open')),
        if (resultReady)
          Text(
            result != null ? 'applied' : 'cancelled',
            key: const Key('result'),
          ),
      ],
    );
  }
}

Widget _host(List<MihonFilter> filters) => MaterialApp(
      home: Scaffold(body: _SheetHost(filters: filters)),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MihonFilterSheet — controls render', () {
    testWidgets('every MihonFilter variant renders a visible control',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // MihonSelect → DropdownButton<int>
      expect(find.byType(DropdownButton<int>), findsAtLeastNWidgets(1));
      // MihonText → labeled TextField
      expect(find.text('Author'), findsOneWidget);
      // MihonTriState label
      expect(find.text('Completed'), findsOneWidget);
      // MihonCheckBox → Switch inside SwitchListTile
      expect(find.byType(Switch), findsAtLeastNWidgets(1));
      // MihonSort label
      expect(find.text('Sort By'), findsOneWidget);
      // MihonGroup header (ExpansionTile title)
      expect(find.text('Genres'), findsOneWidget);

      expect(find.text('Apply'), findsOneWidget);
      expect(find.text('Reset'), findsOneWidget);
    });
  });

  group('MihonFilterSheet — Apply returns a mutated selection', () {
    testWidgets(
        'toggling NSFW then Apply returns a MihonFilter list with state=true',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('NSFW'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('applied'), findsOneWidget);
      expect((filters[3] as MihonCheckBox).state, isTrue);
    });

    testWidgets(
        'the mutated list serialises to a valid MihonFilters selection JSON',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Cycle the TriState filter to "include".
      await tester.tap(find.text('Completed'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Apply returned the mutated in-place list — round-trip it through the
      // selection-JSON encoder/decoder, same as the search screen does.
      final json = MihonFilters.toSelectionJson(filters);
      final reparsed = MihonFilters.parse(json);
      expect(reparsed, hasLength(filters.length));
      expect((reparsed[2] as MihonTriState).state, 1); // Completed → include
    });

    testWidgets('Cancel returns null, not the mutated list', (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('NSFW'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('cancelled'), findsOneWidget);
      expect(find.text('applied'), findsNothing);
    });
  });
}
