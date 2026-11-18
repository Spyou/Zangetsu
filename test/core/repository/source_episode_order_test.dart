import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/repository/source_repository.dart';

Episode _ep(double n, {int? season}) => Episode(
  id: 'e$n',
  title: 'Ep $n',
  number: n,
  url: 'u$n',
  season: season,
);
Episode _epNoNum(String u) => Episode(id: u, title: u, url: u);

void main() {
  group('normalizeEpisodeOrder (any provider order → chronological)', () {
    test('newest-first numbers → ascending 1→N', () {
      final src = <double>[13, 12, 11, 3, 2, 1].map(_ep).toList();
      expect(
        normalizeEpisodeOrder(src).map((e) => e.number).toList(),
        [1, 2, 3, 11, 12, 13],
      );
    });

    test('already chronological is returned unchanged', () {
      final src = <double>[1, 2, 3].map(_ep).toList();
      expect(normalizeEpisodeOrder(src), src);
    });

    test('sorts by (season, number), halves kept (12 → 12.5 → 13)', () {
      final src = [_ep(2, season: 2), _ep(13), _ep(12.5), _ep(1, season: 2)];
      expect(
        normalizeEpisodeOrder(src).map((e) => (e.season, e.number)).toList(),
        [(null, 12.5), (null, 13.0), (2, 1.0), (2, 2.0)],
      );
    });

    test('unnumbered keeps arrival order (direction unprovable)', () {
      final src = [_epNoNum('c'), _epNoNum('b'), _epNoNum('a')];
      expect(normalizeEpisodeOrder(src).map((e) => e.url).toList(), [
        'c',
        'b',
        'a',
      ]);
    });

    test('empty / single list is returned unchanged', () {
      expect(normalizeEpisodeOrder(const <Episode>[]), isEmpty);
      final one = [_epNoNum('x')];
      expect(normalizeEpisodeOrder(one), one);
    });
  });
}
