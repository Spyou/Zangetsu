import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

MediaItem _item(String sourceId, String title) => MediaItem(
  id: '$sourceId-$title',
  title: title,
  url: 'https://example.com/$sourceId',
  type: ProviderType.anime,
  sourceId: sourceId,
);

SourceResultGroup _group(String sourceId, int arrival, List<String> titles) =>
    SourceResultGroup(
      sourceId: sourceId,
      sourceName: sourceId,
      items: [for (final t in titles) _item(sourceId, t)],
      arrivalIndex: arrival,
    );

SearchState _state(
  String query,
  List<SourceResultGroup> groups, {
  SearchSort sort = SearchSort.bestMatch,
}) => SearchState(
  status: SearchStatus.success,
  query: query,
  sort: sort,
  groups: groups,
);

List<String> _order(SearchState s) =>
    s.sortedVisibleGroups.map((g) => g.sourceId).toList();

void main() {
  group('source section ordering (best-match)', () {
    test('the better-matching source leads, even if it arrived later', () {
      final state = _state('one piece', [
        _group('fast', 0, ['One Piece Film: Red']), // prefix (80)
        _group('slow', 1, ['One Piece']), // exact (100), arrived later
      ]);
      expect(_order(state), ['slow', 'fast']);
    });

    test('equally-matching sources keep arrival order (fast-first, no jank)',
        () {
      final state = _state('one piece', [
        _group('fast', 0, ['One Piece']), // exact
        _group('slow', 1, ['One Piece']), // exact — tie
      ]);
      expect(_order(state), ['fast', 'slow']); // arrival tie-break
    });

    // Section (and chip) order ranks by best-matching source whenever there's
    // a query, independent of the item-sort setting — item sort only governs
    // the order of items INSIDE a section (see the item-sort test below).
    test('an explicit item sort still ranks sections by relevance', () {
      final state = _state('one piece', [
        _group('fast', 0, ['One Piece Film: Red']),
        _group('slow', 1, ['One Piece']),
      ], sort: SearchSort.titleAsc);
      expect(_order(state), ['slow', 'fast']); // relevance, not arrival
    });

    test('empty query keeps pure arrival order regardless of sort', () {
      final state = _state('', [
        _group('fast', 0, ['One Piece Film: Red']),
        _group('slow', 1, ['One Piece']),
      ], sort: SearchSort.titleAsc);
      expect(_order(state), ['fast', 'slow']);
    });

    test('the chip row matches the row order (best source first)', () {
      final state = _state('one piece', [
        _group('fast', 0, ['One Piece Film: Red']), // prefix
        _group('slow', 1, ['One Piece']), // exact, arrived later
      ]);
      final chips = state.sourceChipGroups.map((g) => g.sourceId).toList();
      expect(chips, ['slow', 'fast']); // same as _order(state)
      expect(chips, _order(state));
    });

    test('the chip row ranks best-source-first even under a non-bestMatch '
        'sort — chip order is independent of item sort', () {
      final state = _state('one piece', [
        _group('fast', 0, ['One Piece Film: Red']), // prefix
        _group('slow', 1, ['One Piece']), // exact, arrived later
      ], sort: SearchSort.titleAsc);
      final chips = state.sourceChipGroups.map((g) => g.sourceId).toList();
      expect(chips, ['slow', 'fast']); // relevance, not arrival
      expect(chips, _order(state)); // still lines up with the section order
    });
  });
}
