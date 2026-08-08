import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_filters.dart';

// A schema JSON that exercises all 8 filter types in a single payload,
// including a Group that nests a Group (two levels deep) so the recursive
// parse/encode path is actually tested, not just a flat Group of leaves.
const _schema = '''
[
  {"type":"header","name":"Main Filters"},
  {"type":"select","name":"Type","values":["All","Manga","Manhwa"],"state":0},
  {"type":"tristate","name":"Completed","state":0},
  {"type":"sort","name":"Sort By","values":["Popularity","Latest","Title"],"state":{"index":1,"ascending":true}},
  {"type":"group","name":"Genres","filters":[
    {"type":"checkbox","name":"Action","state":false},
    {"type":"checkbox","name":"Comedy","state":false},
    {"type":"group","name":"Demographics","filters":[
      {"type":"checkbox","name":"Shounen","state":false},
      {"type":"tristate","name":"Seinen","state":0}
    ]}
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
      final filters = MihonFilters.parse(_schema);
      expect(filters, hasLength(8));
      expect(filters[0], isA<MihonHeader>());
      expect(filters[1], isA<MihonSelect>());
      expect(filters[2], isA<MihonTriState>());
      expect(filters[3], isA<MihonSort>());
      expect(filters[4], isA<MihonGroup>());
      expect(filters[5], isA<MihonSeparator>());
      expect(filters[6], isA<MihonText>());
      expect(filters[7], isA<MihonSort>());
    });

    test('Header carries correct name', () {
      final header = MihonFilters.parse(_schema)[0] as MihonHeader;
      expect(header.name, 'Main Filters');
    });

    test('Select has correct values and initial state', () {
      final select = MihonFilters.parse(_schema)[1] as MihonSelect;
      expect(select.name, 'Type');
      expect(select.values, ['All', 'Manga', 'Manhwa']);
      expect(select.state, 0);
    });

    test('TriState starts at 0 (ignore)', () {
      final ts = MihonFilters.parse(_schema)[2] as MihonTriState;
      expect(ts.name, 'Completed');
      expect(ts.state, 0);
      expect(ts.isIgnored, isTrue);
      expect(ts.isIncluded, isFalse);
      expect(ts.isExcluded, isFalse);
    });

    test('Sort with state has correct index and ascending', () {
      final sort = MihonFilters.parse(_schema)[3] as MihonSort;
      expect(sort.name, 'Sort By');
      expect(sort.values, ['Popularity', 'Latest', 'Title']);
      expect(sort.index, 1);
      expect(sort.ascending, isTrue);
    });

    test('top-level Group contains 2 checkboxes + 1 nested Group', () {
      final group = MihonFilters.parse(_schema)[4] as MihonGroup;
      expect(group.name, 'Genres');
      expect(group.children, hasLength(3));
      expect(group.children[0], isA<MihonCheckBox>());
      expect(group.children[1], isA<MihonCheckBox>());
      expect(group.children[2], isA<MihonGroup>());
      expect((group.children[0] as MihonCheckBox).name, 'Action');
      expect((group.children[1] as MihonCheckBox).name, 'Comedy');
    });

    test('nested Group (2 levels deep) parses its own children correctly', () {
      final group = MihonFilters.parse(_schema)[4] as MihonGroup;
      final nested = group.children[2] as MihonGroup;
      expect(nested.name, 'Demographics');
      expect(nested.children, hasLength(2));
      expect(nested.children[0], isA<MihonCheckBox>());
      expect((nested.children[0] as MihonCheckBox).name, 'Shounen');
      expect(nested.children[1], isA<MihonTriState>());
      expect((nested.children[1] as MihonTriState).name, 'Seinen');
    });

    test('Sort with null state has null index', () {
      final sort = MihonFilters.parse(_schema)[7] as MihonSort;
      expect(sort.name, 'Unsorted');
      expect(sort.index, isNull);
    });
  });

  // ── 2. toSelectionJson — mutation round-trips correctly, incl. nested Group ─
  group('toSelectionJson after mutations', () {
    test('mutated states appear in output JSON at correct positions', () {
      final filters = MihonFilters.parse(_schema);

      (filters[1] as MihonSelect).state = 2; // "Manhwa"
      (filters[2] as MihonTriState).state = 2; // exclude
      final sort = filters[3] as MihonSort;
      sort.index = 0; // "Popularity"
      sort.ascending = false;

      final topGroup = filters[4] as MihonGroup;
      (topGroup.children[0] as MihonCheckBox).state = true; // Action checked
      final nested = topGroup.children[2] as MihonGroup;
      (nested.children[0] as MihonCheckBox).state = true; // Shounen checked
      (nested.children[1] as MihonTriState).state = 1; // Seinen included

      final json = MihonFilters.toSelectionJson(filters);
      final decoded = jsonDecode(json) as List;

      expect(decoded, hasLength(8));

      expect(decoded[0]['type'], 'header');

      expect(decoded[1]['type'], 'select');
      expect(decoded[1]['state'], 2);

      expect(decoded[2]['type'], 'tristate');
      expect(decoded[2]['state'], 2);

      expect(decoded[3]['type'], 'sort');
      expect(decoded[3]['state']['index'], 0);
      expect(decoded[3]['state']['ascending'], isFalse);

      expect(decoded[4]['type'], 'group');
      final topFilters = decoded[4]['filters'] as List;
      expect(topFilters[0]['type'], 'checkbox');
      expect(topFilters[0]['state'], isTrue);
      expect(topFilters[1]['state'], isFalse);
      expect(topFilters[2]['type'], 'group');
      final nestedFilters = topFilters[2]['filters'] as List;
      expect(nestedFilters[0]['type'], 'checkbox');
      expect(nestedFilters[0]['state'], isTrue);
      expect(nestedFilters[1]['type'], 'tristate');
      expect(nestedFilters[1]['state'], 1);

      expect(decoded[5]['type'], 'separator');

      // Unmutated null-state Sort stays null.
      expect(decoded[7]['state'], isNull);
    });
  });

  // ── 3. Round-trip stability, incl. Sort (both fields) + nested Group ────────
  group('round-trip', () {
    test('parse(toSelectionJson(parse(schema))) yields equivalent states', () {
      final first = MihonFilters.parse(_schema);

      (first[1] as MihonSelect).state = 1;
      (first[2] as MihonTriState).state = 1;
      final sort = first[3] as MihonSort;
      sort.index = 2; // "Title"
      sort.ascending = false;
      final nested = (first[4] as MihonGroup).children[2] as MihonGroup;
      (nested.children[1] as MihonTriState).state = 2; // Seinen excluded

      final selJson = MihonFilters.toSelectionJson(first);
      final second = MihonFilters.parse(selJson);

      expect(second, hasLength(first.length));
      expect((second[1] as MihonSelect).state, 1);
      expect((second[2] as MihonTriState).state, 1);

      // Sort: BOTH fields (index and ascending) survive the round trip —
      // a composite-state bug (e.g. only index serialised) would surface here.
      final secondSort = second[3] as MihonSort;
      expect(secondSort.index, 2);
      expect(secondSort.ascending, isFalse);

      // Nested Group survives two levels deep.
      final secondTop = second[4] as MihonGroup;
      expect(secondTop.children, hasLength(3));
      final secondNested = secondTop.children[2] as MihonGroup;
      expect(secondNested.children, hasLength(2));
      expect((secondNested.children[1] as MihonTriState).state, 2);
    });
  });

  // ── 4. Defensive — never throws on bad input ─────────────────────────────
  group('defensive parse', () {
    test('parse("not json") returns empty list without throwing', () {
      expect(() => MihonFilters.parse('not json'), returnsNormally);
      expect(MihonFilters.parse('not json'), isEmpty);
    });

    test('parse with unknown type skips that element', () {
      const input = '[{"type":"bogus","name":"x"},{"type":"header","name":"H"}]';
      expect(() => MihonFilters.parse(input), returnsNormally);
      final result = MihonFilters.parse(input);
      expect(result, hasLength(1));
      expect(result[0], isA<MihonHeader>());
    });

    test('parse of a top-level non-array returns empty list', () {
      expect(MihonFilters.parse('{"type":"header"}'), isEmpty);
    });

    test('parse of empty array returns empty list', () {
      expect(MihonFilters.parse('[]'), isEmpty);
    });

    test('out-of-range Select state is clamped to 0', () {
      const input = '''
[
  {"type":"select","name":"Type","values":["All","Manga","Manhwa"],"state":99},
  {"type":"select","name":"Empty","values":[],"state":0}
]
''';
      final filters = MihonFilters.parse(input);
      expect(filters, hasLength(2));
      expect((filters[0] as MihonSelect).state, 0,
          reason: 'out-of-range state 99 must be clamped to 0');
      expect((filters[1] as MihonSelect).state, 0,
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
      final filters = MihonFilters.parse(input);
      expect(filters, hasLength(3));
      expect((filters[0] as MihonSort).index, isNull,
          reason: 'index 99 >= values.length(2) must become null');
      expect((filters[1] as MihonSort).index, isNull,
          reason: 'negative index must become null');
      expect((filters[2] as MihonSort).index, isNull,
          reason: 'any index into empty values list must become null');
    });

    test('malformed nested group (filters not a list) yields empty children, not a throw', () {
      const input = '[{"type":"group","name":"Broken","filters":"not-a-list"}]';
      expect(() => MihonFilters.parse(input), returnsNormally);
      final group = MihonFilters.parse(input)[0] as MihonGroup;
      expect(group.children, isEmpty);
    });
  });
}
