// The genre filter used to check whether the TITLE STRING mentioned the
// keyword (e.g. "Action") instead of real genre data, so picking a genre
// almost always returned nothing. This covers the real match against
// MediaItem.genres plus the derived availableGenres pill list.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

MediaItem _item(
  String title, {
  List<String> genres = const [],
  String sourceId = 'src',
}) => MediaItem(
  id: 'id-$title',
  title: title,
  url: 'https://example.com/$title',
  type: ProviderType.anime,
  sourceId: sourceId,
  genres: genres,
);

void main() {
  group('SearchMeta.matchesGenre', () {
    test('matches a real genre case-insensitively', () {
      final item = _item('Some Show', genres: const ['Action']);
      expect(SearchMeta.matchesGenre(item, 'action'), isTrue);
      expect(SearchMeta.matchesGenre(item, 'Action'), isTrue);
    });

    test('title text alone is no longer enough — the old bug', () {
      // Title literally contains "action" but carries no genre data.
      final item = _item('Action Man', genres: const []);
      expect(SearchMeta.matchesGenre(item, 'Action'), isFalse);
    });

    test('an item with no genres never matches a specific genre', () {
      final item = _item('Some Show', genres: const []);
      expect(SearchMeta.matchesGenre(item, 'Action'), isFalse);
    });
  });

  group('SearchState genre filtering (_passes)', () {
    test('active genre filter excludes items with no genre data', () {
      final state = SearchState(
        genreFilter: 'Action',
        groups: [
          SourceResultGroup(
            sourceId: 'src',
            sourceName: 'src',
            items: [
              _item('Has genre', genres: const ['Action']),
              _item('No genre data', genres: const []),
            ],
          ),
        ],
      );
      expect(
        state.visibleResults.map((i) => i.title),
        ['Has genre'],
      );
    });

    test('no genre filter ("Any") lets everything through regardless of '
        'genre data', () {
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'src',
            sourceName: 'src',
            items: [
              _item('Has genre', genres: const ['Action']),
              _item('No genre data', genres: const []),
            ],
          ),
        ],
      );
      expect(state.visibleResults.length, 2);
    });
  });

  group('SearchState.availableGenres', () {
    test('dedupes case-insensitively, keeping first-seen capitalisation, '
        'sorted alphabetically', () {
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'a',
            sourceName: 'a',
            items: [
              _item('One', genres: const ['Action', 'Comedy']),
              _item('Two', genres: const ['action', 'Drama']),
            ],
          ),
        ],
      );
      expect(state.availableGenres, ['Action', 'Comedy', 'Drama']);
    });

    test('caps at 20 pills', () {
      final genres = [for (var i = 0; i < 30; i++) 'Genre$i'];
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'a',
            sourceName: 'a',
            items: [_item('One', genres: genres)],
          ),
        ],
      );
      expect(state.availableGenres.length, 20);
    });
  });

  group('SearchState.hasItemsWithoutGenre', () {
    test('true when at least one result across groups has no genre data', () {
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'a',
            sourceName: 'a',
            items: [
              _item('Has genre', genres: const ['Action']),
              _item('No genre data'),
            ],
          ),
        ],
      );
      expect(state.hasItemsWithoutGenre, isTrue);
    });

    test('false when every result carries genre data', () {
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'a',
            sourceName: 'a',
            items: [_item('Has genre', genres: const ['Action'])],
          ),
        ],
      );
      expect(state.hasItemsWithoutGenre, isFalse);
    });
  });
}
