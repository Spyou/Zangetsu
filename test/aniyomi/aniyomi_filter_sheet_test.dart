import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';
import 'package:watch_app/features/aniyomi/aniyomi_filter_sheet.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a fresh, independent filter list for each test so mutations in one
/// test don't bleed into another.
List<AniyomiFilter> _makeFilters() => [
      AniyomiSelect(name: 'Type', values: ['All', 'Movie', 'TV'], state: 0),
      AniyomiTriState(name: 'Subtitled', state: 0),
      AniyomiCheckBox(name: 'Dubbed', state: false),
      AniyomiSort(
        name: 'Sort By',
        values: ['Popularity', 'Rating'],
        index: null,
        ascending: true,
      ),
      AniyomiGroup(
        name: 'Genres',
        children: [AniyomiCheckBox(name: 'Action', state: false)],
      ),
    ];

/// Host widget: tap 'Open' to show the sheet; result is stored so tests can
/// assert on it after the sheet closes.
class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.filters});
  final List<AniyomiFilter> filters;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  List<AniyomiFilter>? result;
  bool resultReady = false;

  Future<void> _open() async {
    final r = await showAniyomiFilterSheet(context, widget.filters);
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

Widget _host(List<AniyomiFilter> filters) => MaterialApp(
      home: Scaffold(body: _SheetHost(filters: filters)),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── 1. Controls render ───────────────────────────────────────────────────
  group('AniyomiFilterSheet — controls render', () {
    testWidgets('all expected control types are visible when the sheet opens',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // AniyomiSelect → DropdownButton<int>
      expect(find.byType(DropdownButton<int>), findsAtLeastNWidgets(1));

      // AniyomiCheckBox → Switch inside SwitchListTile
      expect(find.byType(Switch), findsAtLeastNWidgets(1));

      // AniyomiTriState label is visible
      expect(find.text('Subtitled'), findsOneWidget);

      // AniyomiSort label is visible
      expect(find.text('Sort By'), findsOneWidget);

      // AniyomiGroup header (ExpansionTile title) is visible
      expect(find.text('Genres'), findsOneWidget);

      // Action buttons
      expect(find.text('Apply'), findsOneWidget);
      expect(find.text('Reset'), findsOneWidget);
    });
  });

  // ── 2. Apply returns the mutated list ───────────────────────────────────
  group('AniyomiFilterSheet — Apply returns mutated list', () {
    testWidgets(
        'toggling the switch then tapping Apply returns CheckBox state=true',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Tap the 'Dubbed' SwitchListTile row — tapping anywhere on the tile
      // (including the title text) triggers its onChanged callback.
      await tester.tap(find.text('Dubbed'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Host shows 'applied' → non-null return
      expect(find.text('applied'), findsOneWidget);

      // Mutation was persisted to the original filter object (in-place edit).
      expect((filters[2] as AniyomiCheckBox).state, isTrue);
    });

    testWidgets(
        'cycling TriState once then tapping Apply returns state=1 (include)',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // The TriState row wraps the name text in a tappable InkWell; tapping
      // the label text cycles the state 0 → 1 (ignore → include).
      await tester.tap(find.text('Subtitled'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('applied'), findsOneWidget);
      expect((filters[1] as AniyomiTriState).state, 1);
    });

    testWidgets(
        'toggling a switch then tapping Cancel returns null (not the mutated list)',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Toggle 'Dubbed' so there is a meaningful pending change.
      await tester.tap(find.text('Dubbed'));
      await tester.pumpAndSettle();

      // Cancel — the sheet must return null regardless of in-flight mutations.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Host shows 'cancelled' → null return value confirmed.
      expect(find.text('cancelled'), findsOneWidget);
      expect(find.text('applied'), findsNothing);
    });

    testWidgets(
        'changing Select index then tapping Apply returns updated state',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Open the Type DropdownButton<int> (currently shows 'All' at index 0).
      await tester.tap(find.byType(DropdownButton<int>).first);
      await tester.pumpAndSettle();

      // Choose 'Movie' (index 1). Use .last because the closed-dropdown
      // label and the open menu item both carry the same text.
      await tester.tap(find.text('Movie').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('applied'), findsOneWidget);
      expect((filters[0] as AniyomiSelect).state, 1);
    });

    testWidgets(
        'selecting Sort column and toggling direction then Apply returns updated Sort',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Open the Sort column DropdownButton<int?> (shows 'None' hint,
      // index=null). The Select filter uses DropdownButton<int> (non-nullable)
      // so the generic type distinguishes the two dropdowns.
      await tester.tap(find.byType(DropdownButton<int?>).first);
      await tester.pumpAndSettle();

      // Choose 'Popularity' (index 0).
      await tester.tap(find.text('Popularity').last);
      await tester.pumpAndSettle();

      // Toggle direction: default is ascending=true; tap the up-arrow to flip.
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('applied'), findsOneWidget);
      final sort = filters[3] as AniyomiSort;
      expect(sort.index, 0);
      expect(sort.ascending, isFalse);
    });
  });

  // ── 3. Reset restores defaults ───────────────────────────────────────────
  group('AniyomiFilterSheet — Reset restores defaults', () {
    testWidgets(
        'toggling switch then tapping Reset returns checkbox to false on Apply',
        (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Set Dubbed to true.
      await tester.tap(find.text('Dubbed'));
      await tester.pumpAndSettle();

      // Reset — must not close the sheet.
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      // Sheet is still open (no 'applied'/'cancelled' key yet).
      expect(find.byKey(const Key('result')), findsNothing);

      // Apply — now with reset (false) state.
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('applied'), findsOneWidget);
      expect((filters[2] as AniyomiCheckBox).state, isFalse);
    });

    testWidgets('Reset cycles TriState back to 0 (ignore)', (tester) async {
      final filters = _makeFilters();
      await tester.pumpWidget(_host(filters));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Cycle Subtitled to 1.
      await tester.tap(find.text('Subtitled'));
      await tester.pumpAndSettle();

      // Reset brings it back to 0.
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect((filters[1] as AniyomiTriState).state, 0);
    });
  });
}
