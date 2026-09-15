import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/reader_page_queue.dart';

void main() {
  /// A queue whose fetches finish only when the test says so, so ordering can
  /// be asserted rather than raced.
  late List<String> started;
  late Map<String, Completer<void>> gates;
  late ReaderPageQueue queue;

  setUp(() {
    started = [];
    gates = {};
    queue = ReaderPageQueue(
      fetch: (key) {
        started.add(key);
        return (gates[key] ??= Completer<void>()).future;
      },
    );
  });

  Future<void> finish(String key) async {
    (gates[key] ??= Completer<void>()).complete();
    await Future<void>.delayed(Duration.zero);
  }

  group('ReaderPageQueue', () {
    // The reported symptom: pages arriving in whatever order the network
    // happened to finish them, rather than the order they are read in.
    test('fetches one at a time, in the order asked for', () async {
      queue
        ..add('a', PagePriority.adjacent)
        ..add('b', PagePriority.adjacent)
        ..add('c', PagePriority.adjacent);
      await Future<void>.delayed(Duration.zero);

      expect(started, ['a'], reason: 'only one request in flight');
      await finish('a');
      expect(started, ['a', 'b']);
      await finish('b');
      expect(started, ['a', 'b', 'c']);
    });

    test('the page being looked at jumps ahead of read-ahead', () async {
      queue
        ..add('a', PagePriority.adjacent)
        ..add('b', PagePriority.adjacent)
        ..add('c', PagePriority.adjacent);
      await Future<void>.delayed(Duration.zero);
      // 'a' is already in flight; 'c' becomes the visible page.
      queue.add('c', PagePriority.current);

      await finish('a');
      expect(started, ['a', 'c'], reason: 'c overtakes b');
      await finish('c');
      expect(started, ['a', 'c', 'b']);
    });

    test('a retry beats everything still waiting', () async {
      queue
        ..add('a', PagePriority.adjacent)
        ..add('b', PagePriority.adjacent)
        ..add('c', PagePriority.current);
      await Future<void>.delayed(Duration.zero);
      queue.add('b', PagePriority.retry);

      await finish('a');
      expect(started, ['a', 'b']);
    });

    test('scrolling away drops pages that never started', () async {
      queue
        ..add('a', PagePriority.adjacent)
        ..add('b', PagePriority.adjacent)
        ..add('c', PagePriority.adjacent);
      await Future<void>.delayed(Duration.zero);

      queue.keepOnly({'a', 'c'}); // 'b' is no longer near the reader
      expect(queue.pendingKeys, ['c']);

      await finish('a');
      expect(started, ['a', 'c'], reason: 'b was dropped, never fetched');
    });

    test('an in-flight fetch is never cancelled by keepOnly', () async {
      queue.add('a', PagePriority.current);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a']);

      queue.keepOnly({'z'}); // 'a' is already downloading
      await finish('a');
      expect(started, [
        'a',
      ], reason: 'the part-done download was not thrown away');
    });

    test('the same page is never fetched twice', () async {
      queue.add('a', PagePriority.current);
      await Future<void>.delayed(Duration.zero);
      await finish('a');

      queue.add('a', PagePriority.current);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a']);
    });

    test('a failing page does not stall the queue', () async {
      final q = ReaderPageQueue(
        fetch: (key) async {
          started.add(key);
          if (key == 'a') throw StateError('boom');
        },
      );
      q
        ..add('a', PagePriority.current)
        ..add('b', PagePriority.adjacent);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, ['a', 'b']);
    });
  });
}
