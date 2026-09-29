import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_mapping.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';

void main() {
  test('parses Stremio-style season and episode labels', () {
    final episode = episodeFromSEpisode({
      'url': 's2e1',
      'name': 'S02 E01 - The Return',
      'episode_number': 1.0,
    });

    expect(episode.season, 2);
    expect(episode.number, 1);
    expect(episode.id, 's2e1.0');
  });

  test('orders and deduplicates non-anime multi-season episodes', () {
    final raw = [
      // The addon reports an absolute number here; the title is authoritative.
      {'url': 's2e1-b', 'name': 'Season 2 Episode 1', 'episode_number': 7.0},
      {'url': 's1e2', 'name': 'S1E2', 'episode_number': 2.0},
      {'url': 's1e1', 'name': '1x01', 'episode_number': 1.0},
      {'url': 'range-copy', 'name': 'S1E1 (1-6)', 'episode_number': 1.0},
      {'url': 's2e2', 'name': 'S2E2', 'episode_number': 2.0},
      {'url': 's2e1-a', 'name': 'S2E1', 'episode_number': 1.0},
    ];

    final episodes = sortEpisodesAscending(
      raw.map(episodeFromSEpisode).toList(),
    );

    expect(episodes.map((e) => '${e.season}:${e.number}').toList(), [
      '1:1.0',
      '1:2.0',
      '2:1.0',
      '2:2.0',
    ]);
  });

  test('supports mixed season labels without turning ranges into seasons', () {
    final raw = [
      {'url': 'a', 'name': 'S02 - E01 - Return (1-6)', 'episode_number': 6.0},
      {'url': 'b', 'name': '1x02 - Second', 'episode_number': 2.0},
      {'url': 'c', 'name': 'S01E01 - First', 'episode_number': 1.0},
      {'url': 'd', 'name': 'S02E01 - Return', 'episode_number': 1.0},
    ];

    final episodes = sortEpisodesAscending(
      raw.map(episodeFromSEpisode).toList(),
    );

    expect(episodes.map((e) => '${e.season}:${e.number}').toList(), [
      '1:1.0',
      '1:2.0',
      '2:1.0',
    ]);
  });

  test('splits Stremio pipe headers from the playable URL', () {
    final source = videoSourceFromVideo({
      'videoUrl':
          'https://cdn.example/video.m3u8|Referer=https%3A%2F%2Fstremio.example&User-Agent=Test%20Agent',
      'videoTitle': '1080p',
    });

    expect(source.url, 'https://cdn.example/video.m3u8');
    expect(source.headers, {
      'Referer': 'https://stremio.example',
      'User-Agent': 'Test Agent',
    });
  });
}
