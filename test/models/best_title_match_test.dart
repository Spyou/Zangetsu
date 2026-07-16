import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

MediaItem _item(String title, {String? english, int? malId}) => MediaItem(
      id: title,
      title: title,
      englishTitle: english,
      url: title,
      type: ProviderType.anime,
      sourceId: 'src',
      malId: malId,
    );

void main() {
  group('bestTitleMatch', () {
    test('returns null for empty results', () {
      expect(bestTitleMatch([], 'anything'), isNull);
    });

    test('prefers an exact (normalized) title match over the first result', () {
      // The reported bug: source ranked "III" first; tapping season 1 must open
      // season 1, not results.first.
      final results = [
        _item('Mushoku Tensei III: Isekai Ittara Honki Dasu'),
        _item('Mushoku Tensei: Jobless Reincarnation'),
      ];
      final match = bestTitleMatch(results, 'Mushoku Tensei: Jobless Reincarnation');
      expect(match!.title, 'Mushoku Tensei: Jobless Reincarnation');
    });

    test('matches ignoring punctuation/case', () {
      final results = [_item('Attack on Titan Final'), _item('ATTACK ON TITAN!')];
      expect(bestTitleMatch(results, 'attack on titan')!.title, 'ATTACK ON TITAN!');
    });

    test('matches on englishTitle too', () {
      final results = [
        _item('Shingeki no Kyojin', english: 'Attack on Titan'),
        _item('Other'),
      ];
      expect(bestTitleMatch(results, 'Attack on Titan')!.title, 'Shingeki no Kyojin');
    });

    test('falls back to the first result when nothing matches', () {
      final results = [_item('First'), _item('Second')];
      expect(bestTitleMatch(results, 'Unrelated')!.title, 'First');
    });

    test('prefers a MAL id match over title, even when titles differ', () {
      // Source names season 1 differently than AniList, so title won't match —
      // but the MAL id does, so it must still open season 1.
      final results = [
        _item('Mushoku Tensei III', malId: 111),
        _item('Mushoku Tensei', malId: 222),
      ];
      final match = bestTitleMatch(
        results,
        'Mushoku Tensei: Jobless Reincarnation',
        wantedMalId: 222,
      );
      expect(match!.malId, 222);
    });

    test('ignores a null MAL id and falls through to title match', () {
      final results = [_item('First', malId: 1), _item('Target', malId: 2)];
      final match =
          bestTitleMatch(results, 'Target', wantedMalId: null);
      expect(match!.title, 'Target');
    });

    test('matches the Romaji alt title when the source indexes by Romaji', () {
      // The real bug: metadata gives English, source lists Romaji, no malId.
      final results = [
        _item('Mushoku Tensei III: Isekai Ittara Honki Dasu'),
        _item('Mushoku Tensei II: Isekai Ittara Honki Dasu Part 2'),
        _item('Mushoku Tensei: Isekai Ittara Honki Dasu'),
      ];
      final match = bestTitleMatch(
        results,
        'Mushoku Tensei: Jobless Reincarnation Season 2 Part 2',
        altTitle: 'Mushoku Tensei II: Isekai Ittara Honki Dasu Part 2',
      );
      expect(match!.title, 'Mushoku Tensei II: Isekai Ittara Honki Dasu Part 2');
    });
  });
}
