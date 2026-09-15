import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

/// Provider calls run strictly one at a time. A detail fetch nobody is waiting
/// for still held that queue, so opening three titles five seconds apart made
/// them take 12s, 24s and 27s in a shared report — each waiting out the ones
/// already backed out of.
///
/// This models the queue itself: chained jobs, each asked on its way in
/// whether its caller has gone.
void main() {
  late Future<void> queue;
  late List<String> ran;

  setUp(() {
    queue = Future<void>.value();
    ran = [];
  });

  Future<T> serialized<T>(
    String tag,
    Future<T> Function() action, {
    bool Function()? abandoned,
  }) {
    final done = Completer<T>();
    final prev = queue;
    queue = done.future.then<void>((_) {}, onError: (_) {});
    prev.whenComplete(() {
      if (abandoned?.call() ?? false) {
        done.completeError(const ProviderCallAbandoned());
        return;
      }
      ran.add(tag);
      action().then(done.complete, onError: done.completeError);
    });
    return done.future;
  }

  test('a job whose caller left never runs, so the next one starts', () async {
    var firstGone = false;
    final first = serialized('first', () async => 1, abandoned: () => firstGone);
    final second = serialized('second', () async => 2);

    // Backed out while it sat in the queue.
    firstGone = true;

    await expectLater(first, throwsA(isA<ProviderCallAbandoned>()));
    expect(await second, 2);
    expect(ran, ['second'], reason: 'the abandoned job must not have run');
  });

  test('nobody leaving means everything runs, in order — unchanged', () async {
    final a = serialized('a', () async => 'a');
    final b = serialized('b', () async => 'b');
    expect(await a, 'a');
    expect(await b, 'b');
    expect(ran, ['a', 'b']);
  });

  test('no abandoned callback at all behaves exactly as before', () async {
    expect(await serialized('x', () async => 7), 7);
    expect(ran, ['x']);
  });

  test('one abandoned job does not poison the rest of the queue', () async {
    var gone = true;
    final dead = serialized('dead', () async => 0, abandoned: () => gone);
    await expectLater(dead, throwsA(isA<ProviderCallAbandoned>()));
    gone = false;
    expect(await serialized('alive', () async => 9), 9);
    expect(ran, ['alive']);
  });
}
