import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

MediaItem _item(String sourceId, {String title = 'Demon Slayer'}) => MediaItem(
  id: 'id-$sourceId',
  title: title,
  url: 'https://example.com/$sourceId',
  type: ProviderType.anime,
  sourceId: sourceId,
);

SourceResultGroup _group(String sourceId, {int arrival = 0}) =>
    SourceResultGroup(
      sourceId: sourceId,
      sourceName: sourceId,
      items: [_item(sourceId)],
      arrivalIndex: arrival,
    );

void main() {
  group('ecosystemOf', () {
    test('maps the `ani:` prefix to Aniyomi', () {
      expect(ecosystemOf('ani:1'), SearchEcosystem.aniyomi);
      expect(ecosystemOf('ani:hianime'), SearchEcosystem.aniyomi);
    });

    test('maps the `cs:` prefix to CloudStream', () {
      expect(ecosystemOf('cs:AnimePahe'), SearchEcosystem.cloudstream);
      expect(ecosystemOf('cs:MovieBox@cncverse'), SearchEcosystem.cloudstream);
    });

    test('maps anything else to Zangetsu', () {
      expect(ecosystemOf('allanime'), SearchEcosystem.zangetsu);
      expect(ecosystemOf('netmirror'), SearchEcosystem.zangetsu);
      // No colon → not an Aniyomi/CloudStream id, so it stays Zangetsu.
      expect(ecosystemOf('anilist'), SearchEcosystem.zangetsu);
      expect(ecosystemOf('csfd'), SearchEcosystem.zangetsu);
      expect(ecosystemOf(''), SearchEcosystem.zangetsu);
    });

    test('never returns the All sentinel', () {
      for (final id in ['ani:1', 'cs:x', 'allanime', '']) {
        expect(ecosystemOf(id), isNot(SearchEcosystem.all));
      }
    });
  });

  group('ecosystemTabsFor (hide-empty-ecosystem logic)', () {
    test('always includes All, even with no sources', () {
      expect(ecosystemTabsFor(const []), [SearchEcosystem.all]);
    });

    test('only Zangetsu sources → All + Zangetsu (no CS/Ani tabs)', () {
      expect(ecosystemTabsFor(const ['allanime', 'netmirror']), [
        SearchEcosystem.all,
        SearchEcosystem.zangetsu,
      ]);
    });

    test('no Aniyomi source → no Aniyomi tab', () {
      final tabs = ecosystemTabsFor(const ['allanime', 'cs:AnimePahe']);
      expect(tabs, [
        SearchEcosystem.all,
        SearchEcosystem.zangetsu,
        SearchEcosystem.cloudstream,
      ]);
      expect(tabs, isNot(contains(SearchEcosystem.aniyomi)));
    });

    test('an Aniyomi source makes the Aniyomi tab appear', () {
      final tabs = ecosystemTabsFor(const ['allanime', 'ani:1']);
      expect(tabs, contains(SearchEcosystem.aniyomi));
    });

    test('all three ecosystems present → All + all three, in fixed order', () {
      expect(ecosystemTabsFor(const ['allanime', 'cs:AnimePahe', 'ani:1']), [
        SearchEcosystem.all,
        SearchEcosystem.zangetsu,
        SearchEcosystem.cloudstream,
        SearchEcosystem.aniyomi,
      ]);
    });

    test('order is fixed regardless of input order; no duplicates', () {
      expect(
        ecosystemTabsFor(const ['ani:2', 'ani:1', 'cs:b', 'cs:a', 'zjs']),
        [
          SearchEcosystem.all,
          SearchEcosystem.zangetsu,
          SearchEcosystem.cloudstream,
          SearchEcosystem.aniyomi,
        ],
      );
    });

    test('only an Aniyomi source → All + Aniyomi (no Zangetsu/CS tabs)', () {
      expect(ecosystemTabsFor(const ['ani:1']), [
        SearchEcosystem.all,
        SearchEcosystem.aniyomi,
      ]);
    });
  });

  group('SearchState group filtering by ecosystem', () {
    final groups = [
      _group('allanime', arrival: 0), // Zangetsu
      _group('cs:AnimePahe', arrival: 1), // CloudStream
      _group('ani:1', arrival: 2), // Aniyomi
    ];
    final base = const SearchState().copyWith(
      status: SearchStatus.success,
      groups: groups,
    );

    test('defaults to the All ecosystem', () {
      expect(const SearchState().ecosystem, SearchEcosystem.all);
    });

    test('All tab shows every group (unchanged behaviour)', () {
      expect(base.ecosystem, SearchEcosystem.all);
      expect(base.sortedVisibleGroups.map((g) => g.sourceId), [
        'allanime',
        'cs:AnimePahe',
        'ani:1',
      ]);
      expect(base.totalCount, 3);
      expect(base.visibleResults, hasLength(3));
    });

    test('Zangetsu tab shows only Zangetsu groups', () {
      final s = base.copyWith(ecosystem: SearchEcosystem.zangetsu);
      expect(s.sortedVisibleGroups.map((g) => g.sourceId), ['allanime']);
      expect(s.visibleGroups.map((g) => g.sourceId), ['allanime']);
      expect(s.visibleResults.map((i) => i.sourceId), ['allanime']);
      expect(s.totalCount, 1);
    });

    test('CloudStream tab shows only CloudStream groups', () {
      final s = base.copyWith(ecosystem: SearchEcosystem.cloudstream);
      expect(s.sortedVisibleGroups.map((g) => g.sourceId), ['cs:AnimePahe']);
      expect(s.visibleResults.map((i) => i.sourceId), ['cs:AnimePahe']);
      expect(s.totalCount, 1);
    });

    test('Aniyomi tab shows only Aniyomi groups', () {
      final s = base.copyWith(ecosystem: SearchEcosystem.aniyomi);
      expect(s.sortedVisibleGroups.map((g) => g.sourceId), ['ani:1']);
      expect(s.visibleResults.map((i) => i.sourceId), ['ani:1']);
      expect(s.totalCount, 1);
    });

    test(
      'ecosystem is part of props (states differing by tab are unequal)',
      () {
        expect(
          base,
          isNot(equals(base.copyWith(ecosystem: SearchEcosystem.aniyomi))),
        );
      },
    );

    test('copyWith without ecosystem preserves the active tab', () {
      final s = base.copyWith(ecosystem: SearchEcosystem.cloudstream);
      expect(s.copyWith(query: 'x').ecosystem, SearchEcosystem.cloudstream);
    });
  });
}
