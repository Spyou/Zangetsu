import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';

void main() {
  test(
    'native watch rows keep real indices and metadata without reordering',
    () {
      final rows =
          phoneWatchPageData(
                episodes: const [
                  Episode(
                    id: 'three',
                    title: 'Third',
                    number: 3,
                    season: 2,
                    url: '/3',
                    thumbnail: 'https://cdn/3.jpg',
                    description: 'Episode synopsis',
                  ),
                  Episode(
                    id: 'one',
                    title: 'First',
                    number: 1,
                    url: '/1',
                    unavailable: 'Not out yet',
                  ),
                ],
                showTitle: 'Series',
                showDescription: 'Show synopsis',
                cover: 'https://cdn/cover.jpg',
              )['episodes']
              as List;
      expect(rows.map((dynamic row) => row['index']), [0, 1]);
      expect(rows[0]['number'], 3);
      expect(rows[0]['season'], 2);
      expect(rows[0]['thumb'], 'https://cdn/3.jpg');
      expect(rows[0]['synopsis'], 'Episode synopsis');
      expect(rows[0]['subtitle'], 'Series · S2 E3');
      expect(rows[1]['thumb'], 'https://cdn/cover.jpg');
      expect(rows[1]['unavailable'], 'Not out yet');
    },
  );
  test('empty episode lists need no special native data', () {
    expect(phoneWatchPageData(episodes: const [])['episodes'], isEmpty);
  });
}
