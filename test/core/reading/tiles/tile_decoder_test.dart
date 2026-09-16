import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tiles/tile_decoder.dart';
import 'package:watch_app/core/reading/tiles/tile_pyramid.dart';

const _tileChannel = MethodChannel('zangetsu/tiles');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_tileChannel, null);
    });

    test('available is false off Android', () {
      // The test host is the Dart VM running on the dev machine, not a
      // device — Platform.isAndroid is false here, same as it would be on
      // iOS, which is the whole point: no channel exists there either.
      expect(TileDecoder().available, isFalse);
    });

    test('decode returns null rather than throwing when the channel is '
        'missing', () async {
      // No mock handler installed for zangetsu/tiles: invoking it behaves
      // exactly as it would on a platform that never registered the
      // channel (iOS), which is the failure decode() has to swallow.
      final decoder = TileDecoder();
      final result = await decoder.decode(
        '/some/page.jpg',
        const TileSpec(sample: 1, source: Rect.fromLTWH(0, 0, 10, 10)),
      );
      expect(result, isNull);
    });

    test(
      'dispose() is safe to call twice, and only closes an open page once',
      () async {
        // A bare "call it twice, nothing throws" version of this test would
        // pass even with no idempotency guard at all, since there would be
        // nothing left to close on the second call regardless — so this
        // opens a real page first and counts the native closePage calls,
        // which is what an idempotency regression would actually double up.
        final closeCalls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_tileChannel, (call) async {
          switch (call.method) {
            case 'openPage':
              return {'width': 100, 'height': 100};
            case 'decodeTile':
              return {
                'bytes': Uint8List(4 * 4 * 4),
                'width': 4,
                'height': 4,
              };
            case 'closePage':
              closeCalls.add(call);
              return null;
          }
          return null;
        });

        final decoder = TileDecoder();
        await decoder.decode(
          '/page.jpg',
          const TileSpec(sample: 1, source: Rect.fromLTWH(0, 0, 10, 10)),
        );
        await decoder.dispose();
        await decoder.dispose();

        expect(closeCalls, hasLength(1));
      },
    );

    test(
      'decode sends the source rect UNDIVIDED, with sample as a separate '
      'argument',
      () async {
        // This is the regression test for the coordinate-boundary bug: the
        // old C shim wanted the rect pre-divided by sample, which silently
        // broke every tile once a fixture's dimensions stopped dividing
        // evenly. BitmapRegionDecoder wants original-image coordinates and
        // downsamples on its own via inSampleSize, so nothing here may
        // divide by spec.sample before sending it.
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_tileChannel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'openPage':
              return {'width': 1080, 'height': 6000};
            case 'decodeTile':
              return {
                'bytes': Uint8List(4 * 4 * 4),
                'width': 4,
                'height': 4,
              };
          }
          return null;
        });

        final decoder = TileDecoder();
        const spec = TileSpec(
          sample: 4,
          source: Rect.fromLTWH(100, 200, 300, 400),
        );
        final tile = await decoder.decode('/page.jpg', spec);
        expect(tile, isNotNull);

        final decodeCall = calls.singleWhere((c) => c.method == 'decodeTile');
        expect(decodeCall.arguments, {
          'path': '/page.jpg',
          'x': 100,
          'y': 200,
          'w': 300,
          'h': 400,
          'sample': 4,
        });
      },
    );
  });
}
