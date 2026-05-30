import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';

void main() {
  test('Episode parses number, thumbnail, and filler flag', () {
    final ep = Episode.fromJson({
      'id': 'ep-1', 'title': 'Episode 1', 'number': 1.0,
      'url': 'https://example.test/watch/ep-1',
      'date': '2020-01-01', 'thumbnail': 'https://cdn.test/1.jpg',
      'filler': true,
    });
    expect(ep.number, 1.0);
    expect(ep.filler, true);
    expect(ep.thumbnail, 'https://cdn.test/1.jpg');
  });

  test('Episode defaults filler to false and tolerates missing number', () {
    final ep = Episode.fromJson({
      'id': 'ep-2', 'title': 'Episode 2', 'url': 'https://example.test/2',
    });
    expect(ep.number, isNull);
    expect(ep.filler, false);
  });
}
