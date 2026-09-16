import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tiles/tile_decoder.dart';

void main() {
  group('TileLru', () {
    test('keeps the most recently used and evicts the oldest', () {
      final evicted = <String>[];
      final lru = TileLru(capacity: 3, onEvict: evicted.add);
      lru.touch('a');
      lru.touch('b');
      lru.touch('c');
      expect(evicted, isEmpty);
      lru.touch('d');
      expect(evicted, ['a']);
    });

    test('touching an entry again makes it the newest', () {
      final evicted = <String>[];
      final lru = TileLru(capacity: 3, onEvict: evicted.add);
      lru.touch('a');
      lru.touch('b');
      lru.touch('c');
      lru.touch('a'); // a is now newest, b is oldest
      lru.touch('d');
      expect(evicted, ['b']);
    });

    test('removing an entry evicts it and frees the slot', () {
      final evicted = <String>[];
      final lru = TileLru(capacity: 2, onEvict: evicted.add);
      lru.touch('a');
      lru.touch('b');
      lru.remove('a');
      expect(evicted, ['a']);
      lru.touch('c');
      expect(evicted, ['a'], reason: 'b should still fit');
    });

    test('clearing evicts everything, oldest first', () {
      final evicted = <String>[];
      final lru = TileLru(capacity: 4, onEvict: evicted.add);
      lru.touch('a');
      lru.touch('b');
      lru.clear();
      expect(evicted, ['a', 'b']);
    });

    test('a capacity of one keeps only the newest', () {
      final evicted = <String>[];
      final lru = TileLru(capacity: 1, onEvict: evicted.add);
      lru.touch('a');
      lru.touch('b');
      expect(evicted, ['a']);
    });
  });
}
