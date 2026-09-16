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

    test('contains tracks touch, remove, and clear', () {
      final lru = TileLru(capacity: 3, onEvict: (_) {});
      expect(lru.contains('a'), false);
      expect(lru.length, 0);

      lru.touch('a');
      expect(lru.contains('a'), true);
      expect(lru.length, 1);

      lru.touch('b');
      expect(lru.contains('a'), true);
      expect(lru.contains('b'), true);
      expect(lru.length, 2);

      lru.remove('a');
      expect(lru.contains('a'), false);
      expect(lru.contains('b'), true);
      expect(lru.length, 1);

      lru.clear();
      expect(lru.contains('b'), false);
      expect(lru.length, 0);
    });

    test('remove does not call onEvict for a key that was never added', () {
      final evicted = <String>[];
      final lru = TileLru(capacity: 3, onEvict: evicted.add);
      lru.touch('a');
      lru.remove('b'); // b was never added
      expect(evicted, isEmpty);
      expect(lru.length, 1);
    });
  });

  group('TileDecoder', () {
    test('dispose during isolate startup does not orphan the isolate', () async {
      final decoder = TileDecoder();
      final starting = decoder.startForTest(); // deliberately not awaited
      await decoder.dispose();
      await starting;
      // Let any late assignment inside _ensureStarted land before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(decoder.isolateAliveForTest, isFalse);
    });

    test('dispose after a real start kills the isolate', () async {
      final decoder = TileDecoder();
      await decoder.startForTest();
      expect(decoder.isolateAliveForTest, isTrue);
      await decoder.dispose();
      expect(decoder.isolateAliveForTest, isFalse);
    });

    test('dispose twice concurrently is safe once an isolate exists', () async {
      final decoder = TileDecoder();
      await decoder.startForTest();
      await Future.wait([decoder.dispose(), decoder.dispose()]);
      expect(decoder.isolateAliveForTest, isFalse);
    });
  });
}
