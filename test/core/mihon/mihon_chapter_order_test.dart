import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/models/episode.dart';

Episode _ch(double n) => Episode(id: 'c$n', title: 'Ch $n', number: n, url: 'u$n');
Episode _chNoNum(String u) => Episode(id: u, title: u, url: u);

void main() {
  group('sortChaptersAscending (Mihon newest-first → chronological)', () {
    test('descending numbers → ascending 1→N', () {
      final src = <double>[13, 12, 11, 3, 2, 1].map(_ch).toList();
      expect(
        sortChaptersAscending(src).map((c) => c.number).toList(),
        [1, 2, 3, 11, 12, 13],
      );
    });

    test('specials / half-chapters sort by number (12 → 12.5 → 13)', () {
      final src = <double>[13, 12.5, 12, 1].map(_ch).toList();
      expect(
        sortChaptersAscending(src).map((c) => c.number).toList(),
        [1, 12, 12.5, 13],
      );
    });

    test('no chapter numbers → reversed (source is newest-first)', () {
      final src = [_chNoNum('c'), _chNoNum('b'), _chNoNum('a')];
      expect(sortChaptersAscending(src).map((c) => c.url).toList(), ['a', 'b', 'c']);
    });

    test('empty / single list is returned unchanged', () {
      expect(sortChaptersAscending(const <Episode>[]), isEmpty);
      final one = [_chNoNum('x')];
      expect(sortChaptersAscending(one), one);
    });
  });
}
