import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  test('MediaItem parses a search row and injects sourceId', () {
    final item = MediaItem.fromJson({
      'id': 'one-piece',
      'title': 'One Piece',
      'cover': 'https://cdn.test/op.jpg',
      'coverHeaders': {'Referer': 'https://example.test/'},
      'url': 'https://example.test/anime/one-piece',
      'type': 'anime',
      'sourceId': 'example',
    });
    expect(item.id, 'one-piece');
    expect(item.type, ProviderType.anime);
    expect(item.coverHeaders!['Referer'], 'https://example.test/');
    expect(item.sourceId, 'example');
  });

  test('MediaItem tolerates a missing cover', () {
    final item = MediaItem.fromJson({
      'id': 'x', 'title': 'X', 'url': 'https://x.test',
      'type': 'anime', 'sourceId': 'example',
    });
    expect(item.cover, isNull);
    expect(item.englishTitle, isNull);
  });
}
