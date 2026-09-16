import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tiles/tile_decoder.dart';
import 'package:watch_app/core/reading/tiles/tile_pyramid.dart';

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
    test('dispose called twice concurrently completes both and does not throw',
        () async {
      final decoder = TileDecoder();
      // On the test host tileDecodingAvailable() is false, so the isolate
      // never spawns. This tests the null-isolate path, not the ack handshake.
      await expectLater(
        Future.wait([decoder.dispose(), decoder.dispose()]),
        completes,
      );
    });

    test('decode after dispose returns null', () async {
      final decoder = TileDecoder();
      await decoder.dispose();
      // Even if tileDecodingAvailable() were true and the isolate spawned,
      // decode would return null because _disposing is set. But on the test
      // host it returns null immediately anyway. Either way, it should not throw.
      final spec = TileSpec(
        sample: 1,
        source: ui.Rect.fromLTWH(0, 0, 100, 100),
      );
      final result = await decoder.decode('path', spec);
      expect(result, isNull);
    });
  });
}
