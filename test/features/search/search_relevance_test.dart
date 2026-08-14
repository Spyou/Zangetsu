import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

MediaItem _item(String title, {String? english}) => MediaItem(
  id: 'id-$title',
  title: title,
  englishTitle: english,
  url: 'https://example.com/$title',
  type: ProviderType.anime,
  sourceId: 'src',
);

SearchState _stateFor(String query, List<MediaItem> items) => SearchState(
  status: SearchStatus.success,
  query: query,
  groups: [
    SourceResultGroup(sourceId: 'src', sourceName: 'src', items: items),
  ],
);

List<String> _titles(SearchState s) =>
    s.visibleResults.map((i) => i.title).toList();

void main() {
  group('best-match relevance sort', () {
    test('exact title beats prefix matches buried in source order', () {
      final state = _stateFor('one piece', [
        _item('One Piece Film: Red'),
        _item('One Piece: Stampede'),
        _item('One Piece'), // exact, but last from the source
      ]);
      expect(_titles(state).first, 'One Piece');
    });

    test('ranks exact > prefix > substring > word overlap', () {
      final state = _stateFor('naruto', [
        _item('Boruto: Naruto Next Generations'), // substring
        _item('Naruto Shippuden'), // prefix
        _item('Naruto'), // exact
        _item('The Last: A Movie'), // no match
      ]);
      expect(_titles(state), [
        'Naruto',
        'Naruto Shippuden',
        'Boruto: Naruto Next Generations',
        'The Last: A Movie',
      ]);
    });

    test('matches on the English title too', () {
      final state = _stateFor('attack on titan', [
        _item('Bleach'),
        _item('Shingeki no Kyojin', english: 'Attack on Titan'), // exact (en)
      ]);
      expect(_titles(state).first, 'Shingeki no Kyojin');
    });

    test('equal scores keep the source order', () {
      final state = _stateFor('one piece', [
        _item('One Piece: Stampede'), // prefix
        _item('One Piece Film: Red'), // prefix — same score
      ]);
      // Both prefix-match (80); source order is preserved on the tie.
      expect(_titles(state), ['One Piece: Stampede', 'One Piece Film: Red']);
    });

    test('empty query leaves the order untouched', () {
      final state = _stateFor('', [
        _item('Zeta'),
        _item('Alpha'),
      ]);
      expect(_titles(state), ['Zeta', 'Alpha']);
    });
  });

  group('per-instance score cache (SearchState._scoreCache)', () {
    // visibleResults, sortedVisibleGroups and sourceChipGroups each score the
    // same items via the shared per-instance cache. If a cache entry leaked
    // across passes (wrong key) or went stale on a repeat read, these three
    // — and a second read of each — would disagree.
    test('sortedVisibleGroups, sourceChipGroups and visibleResults agree, '
        'including on a repeat read', () {
      final state = SearchState(
        status: SearchStatus.success,
        query: 'one piece',
        groups: [
          SourceResultGroup(
            sourceId: 'fast',
            sourceName: 'fast',
            items: [_item('One Piece Film: Red')], // prefix (80)
            arrivalIndex: 0,
          ),
          SourceResultGroup(
            sourceId: 'slow',
            sourceName: 'slow',
            items: [_item('One Piece')], // exact (100), arrived later
            arrivalIndex: 1,
          ),
        ],
      );

      List<String> visibleTitles() => _titles(state);
      List<String> sectionOrder() =>
          state.sortedVisibleGroups.map((g) => g.sourceId).toList();
      List<String> chipOrder() =>
          state.sourceChipGroups.map((g) => g.sourceId).toList();

      expect(visibleTitles(), ['One Piece', 'One Piece Film: Red']);
      expect(sectionOrder(), ['slow', 'fast']);
      expect(chipOrder(), ['slow', 'fast']);
      // Re-read every pass a second time on the same instance.
      expect(visibleTitles(), ['One Piece', 'One Piece Film: Red']);
      expect(sectionOrder(), ['slow', 'fast']);
      expect(chipOrder(), ['slow', 'fast']);
    });

    test('a fresh SearchState instance is unaffected by another instance\'s '
        'cached score for an item with the same (sourceId, url)', () {
      final itemA = _item('One Piece'); // sourceId 'src', url .../One Piece
      final s1 = _stateFor('one piece', [itemA]); // itemA exact-matches → 100
      expect(_titles(s1), ['One Piece']); // populates s1's cache for itemA

      // A different query, same underlying item (same sourceId/url) plus a
      // second item that's the exact match for the NEW query. If the cache
      // were wrongly keyed/shared across instances, itemA would still carry
      // s1's stale 100 score here and wrongly tie with (or beat) itemB.
      final itemB = _item('Totally Different Query Text');
      final s2 = _stateFor('totally different query text', [itemA, itemB]);
      expect(_titles(s2), ['Totally Different Query Text', 'One Piece']);
    });
  });
}
