import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  test('MediaDetail parses status, studios, and nested episodes', () {
    final detail = MediaDetail.fromJson({
      'id': 'one-piece',
      'title': 'One Piece',
      'url': 'https://example.test/anime/one-piece',
      'description': 'Pirates.',
      'status': 'ongoing',
      'genres': ['Action', 'Adventure'],
      'studios': ['Toei'],
      'type': 'anime',
      'sourceId': 'example',
      'episodes': [
        {'id': 'ep-1', 'title': 'Episode 1', 'number': 1.0,
         'url': 'https://example.test/watch/ep-1'},
      ],
    });
    expect(detail.status, MediaStatus.ongoing);
    expect(detail.studios, ['Toei']);
    expect(detail.episodes.single.id, 'ep-1');
    expect(detail.type, ProviderType.anime);
  });

  test('MediaDetail defaults status unknown and empty lists', () {
    final detail = MediaDetail.fromJson({
      'id': 'x', 'title': 'X', 'url': 'https://x.test',
      'type': 'anime', 'sourceId': 'example',
    });
    expect(detail.status, MediaStatus.unknown);
    expect(detail.genres, isEmpty);
    expect(detail.episodes, isEmpty);
  });
}
