import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

void main() {
  group('SearchState.aniFiltersBySource', () {
    test('defaults to an empty map', () {
      const state = SearchState();
      expect(state.aniFiltersBySource, isEmpty);
    });

    test('copyWith carries the provided map', () {
      const state = SearchState();
      final updated = state.copyWith(
        aniFiltersBySource: {'ani:1': '["selection"]'},
      );

      expect(updated.aniFiltersBySource, {'ani:1': '["selection"]'});
    });

    test('copyWith without aniFiltersBySource preserves the existing map', () {
      final state = const SearchState().copyWith(
        aniFiltersBySource: {'ani:2': '["sel"]'},
      );
      final again = state.copyWith(query: 'naruto');

      expect(again.aniFiltersBySource, {'ani:2': '["sel"]'});
    });

    test('two states differing only by aniFiltersBySource are unequal', () {
      const a = SearchState();
      final b = a.copyWith(aniFiltersBySource: {'ani:1': '["x"]'});

      expect(a, isNot(equals(b)));
    });

    test('two states with identical aniFiltersBySource are equal', () {
      final a = const SearchState()
          .copyWith(aniFiltersBySource: {'ani:1': '["x"]'});
      final b = const SearchState()
          .copyWith(aniFiltersBySource: {'ani:1': '["x"]'});

      expect(a, equals(b));
    });

    test('aniFiltersBySource is included in props', () {
      final map = {'ani:3': '["v"]'};
      final state = const SearchState().copyWith(aniFiltersBySource: map);

      expect(state.props, contains(map));
    });
  });
}
