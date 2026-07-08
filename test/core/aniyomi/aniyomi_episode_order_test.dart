import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/models/episode.dart';

Episode _ep(double n) => Episode(id: 'e$n', title: 'Ep $n', number: n, url: 'u$n');
Episode _epNoNum(String u) => Episode(id: u, title: u, url: u);

void main() {
  group('sortEpisodesAscending (Aniyomi newest-first → chronological)', () {
    test('descending numbers → ascending 1→N', () {
      final src = <double>[13, 12, 11, 3, 2, 1].map(_ep).toList();
      expect(
        sortEpisodesAscending(src).map((e) => e.number).toList(),
        [1, 2, 3, 11, 12, 13],
      );
    });

    test('specials / half-episodes sort by number (12 → 12.5 → 13)', () {
      final src = <double>[13, 12.5, 12, 1].map(_ep).toList();
      expect(
        sortEpisodesAscending(src).map((e) => e.number).toList(),
        [1, 12, 12.5, 13],
      );
    });

    test('no episode numbers → reversed (source is newest-first)', () {
      // Source order c,b,a (newest-first) → chronological a,b,c.
      final src = [_epNoNum('c'), _epNoNum('b'), _epNoNum('a')];
      expect(sortEpisodesAscending(src).map((e) => e.url).toList(), ['a', 'b', 'c']);
    });

    test('empty / single list is returned unchanged', () {
      expect(sortEpisodesAscending(const <Episode>[]), isEmpty);
      final one = [_epNoNum('x')];
      expect(sortEpisodesAscending(one), one);
    });
  });
}
