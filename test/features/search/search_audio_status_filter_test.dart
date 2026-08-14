// Audio (Subbed/Dubbed) and Status (Ongoing/Completed) both filter on real,
// source-provided data — MediaItem.subCount/dubCount (already drives the
// SUB/DUB badges) and MediaItem.status (carried from Mihon/Aniyomi the same
// way genres were). Also covers the filter sheet's live "Show N results"
// count: SearchState.totalCount is a pure getter over already-fetched
// groups, so it must update the instant a filter changes without a re-search.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

MediaItem _item(
  String title, {
  int? subCount,
  int? dubCount,
  MediaStatus? status,
  String sourceId = 'src',
}) => MediaItem(
  id: 'id-$sourceId-$title',
  title: title,
  url: 'https://example.com/$sourceId/$title',
  type: ProviderType.anime,
  sourceId: sourceId,
  subCount: subCount,
  dubCount: dubCount,
  status: status,
);

void main() {
  group('SearchAudioFilter.matches', () {
    test('any lets everything through, including items with no audio data', () {
      expect(SearchAudioFilter.any.matches(_item('a')), isTrue);
      expect(
        SearchAudioFilter.any.matches(_item('b', subCount: 0, dubCount: 0)),
        isTrue,
      );
    });

    test('subbed requires a positive subCount', () {
      expect(SearchAudioFilter.subbed.matches(_item('a', subCount: 3)), isTrue);
      expect(
        SearchAudioFilter.subbed.matches(_item('a', subCount: 0)),
        isFalse,
      );
      expect(
        SearchAudioFilter.subbed.matches(_item('a')),
        isFalse,
        reason: 'no subCount at all must not pass as subbed',
      );
    });

    test('dubbed requires a positive dubCount', () {
      expect(SearchAudioFilter.dubbed.matches(_item('a', dubCount: 2)), isTrue);
      expect(
        SearchAudioFilter.dubbed.matches(_item('a', dubCount: 0)),
        isFalse,
      );
      expect(SearchAudioFilter.dubbed.matches(_item('a')), isFalse);
    });

    test('an item can be both subbed and dubbed', () {
      final item = _item('a', subCount: 12, dubCount: 12);
      expect(SearchAudioFilter.subbed.matches(item), isTrue);
      expect(SearchAudioFilter.dubbed.matches(item), isTrue);
    });
  });

  group('SearchState audio filtering (_passes)', () {
    test('subbed filter excludes dub-only and audio-less items', () {
      final state = SearchState(
        audioFilter: SearchAudioFilter.subbed,
        groups: [
          SourceResultGroup(
            sourceId: 'src',
            sourceName: 'src',
            items: [
              _item('Subbed', subCount: 1),
              _item('Dub only', dubCount: 1),
              _item('No audio data'),
            ],
          ),
        ],
      );
      expect(state.visibleResults.map((i) => i.title), ['Subbed']);
    });

    test('dubbed filter excludes sub-only items', () {
      final state = SearchState(
        audioFilter: SearchAudioFilter.dubbed,
        groups: [
          SourceResultGroup(
            sourceId: 'src',
            sourceName: 'src',
            items: [_item('Subbed', subCount: 1), _item('Dubbed', dubCount: 1)],
          ),
        ],
      );
      expect(state.visibleResults.map((i) => i.title), ['Dubbed']);
    });

    test('any lets both through', () {
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'src',
            sourceName: 'src',
            items: [_item('Subbed', subCount: 1), _item('Dubbed', dubCount: 1)],
          ),
        ],
      );
      expect(state.visibleResults.length, 2);
    });
  });

  group('SearchStatusFilter.matches', () {
    test(
      'any lets everything through, including items with no status data',
      () {
        expect(SearchStatusFilter.any.matches(_item('a')), isTrue);
        expect(
          SearchStatusFilter.any.matches(
            _item('b', status: MediaStatus.cancelled),
          ),
          isTrue,
        );
      },
    );

    test('ongoing matches only MediaStatus.ongoing', () {
      expect(
        SearchStatusFilter.ongoing.matches(
          _item('a', status: MediaStatus.ongoing),
        ),
        isTrue,
      );
      expect(
        SearchStatusFilter.ongoing.matches(
          _item('a', status: MediaStatus.completed),
        ),
        isFalse,
      );
      expect(
        SearchStatusFilter.ongoing.matches(_item('a')),
        isFalse,
        reason: 'no status data at all must not pass as ongoing',
      );
    });

    test('completed matches only MediaStatus.completed', () {
      expect(
        SearchStatusFilter.completed.matches(
          _item('a', status: MediaStatus.completed),
        ),
        isTrue,
      );
      expect(
        SearchStatusFilter.completed.matches(
          _item('a', status: MediaStatus.hiatus),
        ),
        isFalse,
      );
    });
  });

  group('SearchState status filtering (_passes)', () {
    test('ongoing filter excludes completed and status-less items', () {
      final state = SearchState(
        statusFilter: SearchStatusFilter.ongoing,
        groups: [
          SourceResultGroup(
            sourceId: 'src',
            sourceName: 'src',
            items: [
              _item('Ongoing', status: MediaStatus.ongoing),
              _item('Completed', status: MediaStatus.completed),
              _item('No status data'),
            ],
          ),
        ],
      );
      expect(state.visibleResults.map((i) => i.title), ['Ongoing']);
    });
  });

  group('SearchState.hasAnyStatus', () {
    test('true when at least one result across groups carries a status', () {
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'a',
            sourceName: 'a',
            items: [
              _item('Has status', status: MediaStatus.ongoing),
              _item('No status'),
            ],
          ),
        ],
      );
      expect(state.hasAnyStatus, isTrue);
    });

    test('false when nothing in the result set carries a status — the group '
        'must self-hide, same spirit as availableGenres', () {
      final state = SearchState(
        groups: [
          SourceResultGroup(
            sourceId: 'a',
            sourceName: 'a',
            items: [_item('No status'), _item('Also none')],
          ),
        ],
      );
      expect(state.hasAnyStatus, isFalse);
    });

    test('no groups at all is false, not a crash', () {
      expect(SearchState().hasAnyStatus, isFalse);
    });
  });

  group('hasActiveFilter / activeFilterCount include audio and status', () {
    test('audio alone counts as one active filter', () {
      final state = SearchState(audioFilter: SearchAudioFilter.subbed);
      expect(state.hasActiveFilter, isTrue);
      expect(state.activeFilterCount, 1);
    });

    test('status alone counts as one active filter', () {
      final state = SearchState(statusFilter: SearchStatusFilter.ongoing);
      expect(state.hasActiveFilter, isTrue);
      expect(state.activeFilterCount, 1);
    });

    test('audio + status + a non-default sort all stack in the count', () {
      final state = SearchState(
        sort: SearchSort.newest,
        audioFilter: SearchAudioFilter.dubbed,
        statusFilter: SearchStatusFilter.completed,
      );
      expect(state.activeFilterCount, 3);
    });

    test('defaults for both count as no active filter', () {
      final state = SearchState();
      expect(state.hasActiveFilter, isFalse);
      expect(state.activeFilterCount, 0);
    });
  });

  group('live result count (totalCount) — the "Show N results" source', () {
    final groups = [
      SourceResultGroup(
        sourceId: 'src',
        sourceName: 'src',
        items: [
          _item('Sub Ongoing', subCount: 1, status: MediaStatus.ongoing),
          _item('Sub Completed', subCount: 1, status: MediaStatus.completed),
          _item('Dub Ongoing', dubCount: 1, status: MediaStatus.ongoing),
          _item('Neither'),
        ],
      ),
    ];

    test('counts everything with no filters active', () {
      final state = SearchState(groups: groups);
      expect(state.totalCount, 4);
    });

    test('narrows live as an audio pill is selected — same groups, no '
        're-fetch needed', () {
      final base = SearchState(groups: groups);
      final subbedOnly = base.copyWith(audioFilter: SearchAudioFilter.subbed);
      expect(base.totalCount, 4);
      expect(subbedOnly.totalCount, 2);
      // Same underlying groups object — the count changed purely from the
      // filter selection, confirming it's computed, not re-searched.
      expect(identical(base.groups, subbedOnly.groups), isTrue);
    });

    test('stacking audio + status narrows further', () {
      final state = SearchState(groups: groups).copyWith(
        audioFilter: SearchAudioFilter.subbed,
        statusFilter: SearchStatusFilter.ongoing,
      );
      expect(state.totalCount, 1);
    });

    test('a combination matching nothing counts zero, not an error', () {
      final state = SearchState(groups: groups).copyWith(
        audioFilter: SearchAudioFilter.dubbed,
        statusFilter: SearchStatusFilter.completed,
      );
      expect(state.totalCount, 0);
    });
  });
}
