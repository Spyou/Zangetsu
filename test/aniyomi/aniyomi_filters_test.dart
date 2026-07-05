import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';

// A schema JSON that exercises all 8 filter types in a single payload.
const _schema = '''
[
  {"type":"header","name":"Main Filters"},
  {"type":"select","name":"Type","values":["All","Movie","TV Series"],"state":0},
  {"type":"tristate","name":"Subtitled","state":0},
  {"type":"sort","name":"Sort By","values":["Popularity","Rating","Date"],"state":{"index":1,"ascending":true}},
  {"type":"group","name":"Genres","filters":[
    {"type":"checkbox","name":"Action","state":false},
    {"type":"checkbox","name":"Comedy","state":false}
  ]},
  {"type":"separator","name":""},
  {"type":"text","name":"Search","state":""},
  {"type":"sort","name":"Unsorted","values":["A","B"],"state":null}
]
''';

void main() {
  // ── 1. parse — typed structure and initial state ─────────────────────────
  group('parse', () {
    test('produces correct runtime types in order', () {
      final filters = AniyomiFilters.parse(_schema);
      expect(filters, hasLength(8));
      expect(filters[0], isA<AniyomiHeader>());
      expect(filters[1], isA<AniyomiSelect>());
      expect(filters[2], isA<AniyomiTriState>());
      expect(filters[3], isA<AniyomiSort>());
      expect(filters[4], isA<AniyomiGroup>());
      expect(filters[5], isA<AniyomiSeparator>());
      expect(filters[6], isA<AniyomiText>());
      expect(filters[7], isA<AniyomiSort>());
    });

    test('Header carries correct name', () {
      final header = AniyomiFilters.parse(_schema)[0] as AniyomiHeader;
      expect(header.name, 'Main Filters');
    });

    test('Select has correct values and initial state', () {
      final select = AniyomiFilters.parse(_schema)[1] as AniyomiSelect;
      expect(select.name, 'Type');
      expect(select.values, ['All', 'Movie', 'TV Series']);
      expect(select.state, 0);
    });

    test('TriState starts at 0 (ignore)', () {
      final ts = AniyomiFilters.parse(_schema)[2] as AniyomiTriState;
      expect(ts.name, 'Subtitled');
      expect(ts.state, 0);
      expect(ts.isIgnored, isTrue);
      expect(ts.isIncluded, isFalse);
      expect(ts.isExcluded, isFalse);
    });

    test('Sort with state has correct index and ascending', () {
      final sort = AniyomiFilters.parse(_schema)[3] as AniyomiSort;
      expect(sort.name, 'Sort By');
      expect(sort.values, ['Popularity', 'Rating', 'Date']);
      expect(sort.index, 1);
      expect(sort.ascending, isTrue);
    });

    test('Group contains two CheckBox children with correct names', () {
      final group = AniyomiFilters.parse(_schema)[4] as AniyomiGroup;
      expect(group.name, 'Genres');
      expect(group.children, hasLength(2));
      expect(group.children[0], isA<AniyomiCheckBox>());
      expect(group.children[1], isA<AniyomiCheckBox>());
      expect((group.children[0] as AniyomiCheckBox).name, 'Action');
      expect((group.children[1] as AniyomiCheckBox).name, 'Comedy');
      expect((group.children[0] as AniyomiCheckBox).state, isFalse);
    });

    test('Sort with null state has null index', () {
      final sort = AniyomiFilters.parse(_schema)[7] as AniyomiSort;
      expect(sort.name, 'Unsorted');
      expect(sort.index, isNull);
    });
  });

  // ── 2. toSelectionJson — mutation round-trips correctly ──────────────────
  group('toSelectionJson after mutations', () {
    test('mutated states appear in output JSON at correct positions', () {
      final filters = AniyomiFilters.parse(_schema);

      // Mutate
      (filters[1] as AniyomiSelect).state = 2; // "TV Series"
      (filters[2] as AniyomiTriState).state = 2; // exclude
      final sort = filters[3] as AniyomiSort;
      sort.index = 0; // "Popularity"
      sort.ascending = false;
      ((filters[4] as AniyomiGroup).children[0] as AniyomiCheckBox).state = true; // Action checked

      final json = AniyomiFilters.toSelectionJson(filters);
      final decoded = jsonDecode(json) as List;

      expect(decoded, hasLength(8));

      // Position 0 — header (no state)
      expect(decoded[0]['type'], 'header');
      expect(decoded[0]['name'], 'Main Filters');

      // Position 1 — select, mutated state
      expect(decoded[1]['type'], 'select');
      expect(decoded[1]['state'], 2);
      expect(decoded[1]['values'], ['All', 'Movie', 'TV Series']);

      // Position 2 — tristate, mutated to 2
      expect(decoded[2]['type'], 'tristate');
      expect(decoded[2]['state'], 2);

      // Position 3 — sort, mutated index + direction
      expect(decoded[3]['type'], 'sort');
      expect(decoded[3]['state']['index'], 0);
      expect(decoded[3]['state']['ascending'], isFalse);
      expect(decoded[3]['values'], ['Popularity', 'Rating', 'Date']);

      // Position 4 — group with nested child checkbox checked
      expect(decoded[4]['type'], 'group');
      final groupFilters = decoded[4]['filters'] as List;
      expect(groupFilters[0]['type'], 'checkbox');
      expect(groupFilters[0]['state'], isTrue);
      expect(groupFilters[1]['state'], isFalse);

      // Position 5 — separator
      expect(decoded[5]['type'], 'separator');

      // Position 7 — sort with null state (index still null after no mutation)
      expect(decoded[7]['state'], isNull);
    });
  });

  // ── 3. Round-trip stability ──────────────────────────────────────────────
  group('round-trip', () {
    test('parse(toSelectionJson(parse(schema))) yields equivalent states', () {
      final first = AniyomiFilters.parse(_schema);

      // Mutate the first parse
      (first[1] as AniyomiSelect).state = 1;
      (first[2] as AniyomiTriState).state = 1;

      final selJson = AniyomiFilters.toSelectionJson(first);
      final second = AniyomiFilters.parse(selJson);

      expect(second, hasLength(first.length));
      expect((second[1] as AniyomiSelect).state, 1);
      expect((second[2] as AniyomiTriState).state, 1);
      // Sort state with index preserved
      expect((second[3] as AniyomiSort).index, 1);
      expect((second[3] as AniyomiSort).ascending, isTrue);
      // Group children survive
      expect((second[4] as AniyomiGroup).children, hasLength(2));
    });
  });

  // ── 4. Defensive — never throws on bad input ─────────────────────────────
  group('defensive parse', () {
    test('parse("not json") returns empty list without throwing', () {
      expect(() => AniyomiFilters.parse('not json'), returnsNormally);
      expect(AniyomiFilters.parse('not json'), isEmpty);
    });

    test('parse with unknown type skips that element', () {
      const input = '[{"type":"bogus","name":"x"},{"type":"header","name":"H"}]';
      expect(() => AniyomiFilters.parse(input), returnsNormally);
      final result = AniyomiFilters.parse(input);
      expect(result, hasLength(1));
      expect(result[0], isA<AniyomiHeader>());
    });

    test('parse of a top-level non-array returns empty list', () {
      expect(AniyomiFilters.parse('{"type":"header"}'), isEmpty);
    });

    test('parse of empty array returns empty list', () {
      expect(AniyomiFilters.parse('[]'), isEmpty);
    });

    test('out-of-range Select state is clamped to 0', () {
      const input = '''
[
  {"type":"select","name":"Type","values":["All","Movie","TV"],"state":99},
  {"type":"select","name":"Empty","values":[],"state":0}
]
''';
      final filters = AniyomiFilters.parse(input);
      expect(filters, hasLength(2));
      expect((filters[0] as AniyomiSelect).state, 0,
          reason: 'out-of-range state 99 must be clamped to 0');
      expect((filters[1] as AniyomiSelect).state, 0,
          reason: 'empty values list must also clamp to 0');
    });

    test('out-of-range Sort index is clamped to null', () {
      const input = '''
[
  {"type":"sort","name":"Sort","values":["A","B"],"state":{"index":99,"ascending":true}},
  {"type":"sort","name":"NegIdx","values":["A","B"],"state":{"index":-1,"ascending":false}},
  {"type":"sort","name":"EmptyVals","values":[],"state":{"index":0,"ascending":true}}
]
''';
      final filters = AniyomiFilters.parse(input);
      expect(filters, hasLength(3));
      expect((filters[0] as AniyomiSort).index, isNull,
          reason: 'index 99 >= values.length(2) must become null');
      expect((filters[1] as AniyomiSort).index, isNull,
          reason: 'negative index must become null');
      expect((filters[2] as AniyomiSort).index, isNull,
          reason: 'any index into empty values list must become null');
    });

    test('in-range Select state and Sort index pass through unchanged', () {
      const input = '''
[
  {"type":"select","name":"Type","values":["All","Movie","TV"],"state":2},
  {"type":"sort","name":"Sort","values":["Popularity","Rating"],"state":{"index":1,"ascending":false}}
]
''';
      final filters = AniyomiFilters.parse(input);
      expect((filters[0] as AniyomiSelect).state, 2,
          reason: 'in-range state must not be changed');
      expect((filters[1] as AniyomiSort).index, 1,
          reason: 'in-range index must not be changed');
      expect((filters[1] as AniyomiSort).ascending, isFalse);
    });
  });
}
