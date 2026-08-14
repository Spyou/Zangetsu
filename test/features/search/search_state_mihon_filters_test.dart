// Mihon twin of search_state_ani_filters_test.dart: mihonFiltersBySource is a
// SEPARATE map from aniFiltersBySource (not a shared/renamed one), keyed by
// `mihon:` source ids. filterSelectionFor is the combined lookup the bloc's
// fan-out/browse paths use — it must route each id to its OWN map, and the
// value stored there must round-trip through the matching ecosystem's parser
// (MihonFilters vs AniyomiFilters), never the other one.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';
import 'package:watch_app/core/mihon/mihon_filters.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

void main() {
  group('SearchState.mihonFiltersBySource', () {
    test('defaults to empty', () {
      const state = SearchState();
      expect(state.mihonFiltersBySource, isEmpty);
    });

    test('copyWith sets mihonFiltersBySource', () {
      const state = SearchState();
      final updated = state.copyWith(
        mihonFiltersBySource: {'mihon:1': '["selection"]'},
      );
      expect(updated.mihonFiltersBySource, {'mihon:1': '["selection"]'});
    });

    test('copyWith without mihonFiltersBySource preserves the existing map', () {
      final state = const SearchState().copyWith(
        mihonFiltersBySource: {'mihon:2': '["sel"]'},
      );
      final again = state.copyWith(query: 'x');
      expect(again.mihonFiltersBySource, {'mihon:2': '["sel"]'});
    });

    test('mihonFiltersBySource is independent of aniFiltersBySource', () {
      final state = const SearchState().copyWith(
        aniFiltersBySource: {'ani:1': '["a"]'},
        mihonFiltersBySource: {'mihon:1': '["m"]'},
      );
      expect(state.aniFiltersBySource, {'ani:1': '["a"]'});
      expect(state.mihonFiltersBySource, {'mihon:1': '["m"]'});
    });

    test('mihonFiltersBySource is part of props (state equality)', () {
      final a = const SearchState();
      final b = a.copyWith(mihonFiltersBySource: {'mihon:1': '["x"]'});
      expect(a, isNot(equals(b)));
    });
  });

  group('SearchState.filterSelectionFor — routes by id prefix', () {
    test('a mihon: id reads mihonFiltersBySource, never aniFiltersBySource', () {
      final state = const SearchState().copyWith(
        aniFiltersBySource: {'mihon:1': 'WRONG_MAP'},
        mihonFiltersBySource: {'mihon:1': '["right"]'},
      );
      expect(state.filterSelectionFor('mihon:1'), '["right"]');
    });

    test('an ani: id reads aniFiltersBySource', () {
      final state = const SearchState().copyWith(
        aniFiltersBySource: {'ani:1': '["a"]'},
      );
      expect(state.filterSelectionFor('ani:1'), '["a"]');
    });

    test('an id with no stored selection returns null', () {
      const state = SearchState();
      expect(state.filterSelectionFor('mihon:missing'), isNull);
      expect(state.filterSelectionFor('ani:missing'), isNull);
    });
  });

  group('stored selection round-trips through the matching parser', () {
    test('a Mihon selection round-trips as MihonFilter via MihonFilters.parse', () {
      final original = [MihonCheckBox(name: 'Dubbed', state: true)];
      final json = MihonFilters.toSelectionJson(original);
      final state = const SearchState().copyWith(
        mihonFiltersBySource: {'mihon:1': json},
      );

      final stored = state.filterSelectionFor('mihon:1');
      final parsed = MihonFilters.parse(stored!);

      expect(parsed, hasLength(1));
      expect(parsed.single, isA<MihonCheckBox>());
      expect((parsed.single as MihonCheckBox).state, isTrue);
    });

    test(
      'an Aniyomi selection round-trips as AniyomiFilter via AniyomiFilters.parse',
      () {
        final original = [AniyomiCheckBox(name: 'Dubbed', state: true)];
        final json = AniyomiFilters.toSelectionJson(original);
        final state = const SearchState().copyWith(
          aniFiltersBySource: {'ani:1': json},
        );

        final stored = state.filterSelectionFor('ani:1');
        final parsed = AniyomiFilters.parse(stored!);

        expect(parsed, hasLength(1));
        expect(parsed.single, isA<AniyomiCheckBox>());
        expect((parsed.single as AniyomiCheckBox).state, isTrue);
      },
    );
  });
}
