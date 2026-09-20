import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/source_health_store.dart';

/// Playback health is the signal that catches a source which searches fine but
/// can no longer produce a playable link — the common way a source rots.
///
/// The rules it has to get right are all about NOT convicting a working source:
/// one title missing is not a broken source, retrying the same title is one
/// piece of evidence, and any success clears the slate.
void main() {
  late Directory tmp;
  late SourceHealthStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('playback_health');
    Hive.init(tmp.path);
    await SourceHealthStore.init();
    store = SourceHealthStore();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('counts distinct titles, not attempts', () {
    test('retrying ONE broken title never convicts a source', () async {
      // Someone hammering retry on a title the source genuinely lacks must not
      // get the source marked dead.
      for (var i = 0; i < 20; i++) {
        await store.recordPlayback('ani:1', 'show-a', ok: false);
      }
      expect(store.playbackFailures('ani:1'), 1);
      expect(store.playbackLooksDead('ani:1'), isFalse);
    });

    test('different titles failing does add up', () async {
      for (var i = 0; i < SourceHealthStore.deadAfterTitles; i++) {
        await store.recordPlayback('ani:1', 'show-$i', ok: false);
      }
      expect(
        store.playbackFailures('ani:1'),
        SourceHealthStore.deadAfterTitles,
      );
      expect(store.playbackLooksDead('ani:1'), isTrue);
    });

    test('one under the bar is not dead', () async {
      for (var i = 0; i < SourceHealthStore.deadAfterTitles - 1; i++) {
        await store.recordPlayback('ani:1', 'show-$i', ok: false);
      }
      expect(store.playbackLooksDead('ani:1'), isFalse);
    });
  });

  group('a success clears the slate', () {
    test('one playable link wipes every strike', () async {
      for (var i = 0; i < SourceHealthStore.deadAfterTitles; i++) {
        await store.recordPlayback('ani:1', 'show-$i', ok: false);
      }
      expect(store.playbackLooksDead('ani:1'), isTrue);
      // The path demonstrably works, so the accumulated evidence is wrong.
      await store.recordPlayback('ani:1', 'anything', ok: true);
      expect(store.playbackFailures('ani:1'), 0);
      expect(store.playbackLooksDead('ani:1'), isFalse);
    });

    test('a success on a clean source is a no-op, not a write', () async {
      var notified = 0;
      store.addListener(() => notified++);
      await store.recordPlayback('ani:1', 'show-a', ok: true);
      expect(notified, 0, reason: 'nothing changed, so nothing to notify');
    });
  });

  group('evidence expires', () {
    test('strikes older than the window stop counting', () async {
      final box = Hive.box(SourceHealthStore.boxName);
      final old = DateTime.now()
          .subtract(SourceHealthStore.playbackWindow * 2)
          .millisecondsSinceEpoch;
      box.put('play::ani:1', {
        for (var i = 0; i < SourceHealthStore.deadAfterTitles + 3; i++)
          'stale-$i': old,
      });
      expect(store.playbackFailures('ani:1'), 0);
      expect(store.playbackLooksDead('ani:1'), isFalse);
    });

    test('a fresh strike is not dragged down by stale ones', () async {
      final box = Hive.box(SourceHealthStore.boxName);
      final old = DateTime.now()
          .subtract(SourceHealthStore.playbackWindow * 2)
          .millisecondsSinceEpoch;
      box.put('play::ani:1', {'stale': old});
      await store.recordPlayback('ani:1', 'fresh', ok: false);
      expect(store.playbackFailures('ani:1'), 1);
    });
  });

  group('kept apart from search health', () {
    test('playback strikes never make a source skippable in search', () async {
      // The whole point of a separate record: a source that searches perfectly
      // must keep appearing in search even when playback is broken.
      for (var i = 0; i < SourceHealthStore.deadAfterTitles * 2; i++) {
        await store.recordPlayback('ani:1', 'show-$i', ok: false);
      }
      expect(store.playbackLooksDead('ani:1'), isTrue);
      expect(store.isSkippable('ani:1'), isFalse);
      expect(store.statusOf('ani:1'), SourceHealth.ok);
    });

    test('a search strike does not invent playback failures', () async {
      await store.record('ani:1', SourceOutcome.error);
      expect(store.statusOf('ani:1'), SourceHealth.dead);
      expect(store.playbackFailures('ani:1'), 0);
    });

    test('clear() resets search but LEAVES playback evidence', () async {
      // Search calls clear() when the user retries a failed source. Wiping the
      // playback record there would reset the evidence for anyone who ever
      // hits retry, and this signal would never accumulate.
      await store.record('ani:1', SourceOutcome.error);
      await store.recordPlayback('ani:1', 'show-a', ok: false);
      await store.clear('ani:1');
      expect(store.statusOf('ani:1'), SourceHealth.ok);
      expect(store.playbackFailures('ani:1'), 1);
    });

    test('clearPlayback() is the other half', () async {
      await store.recordPlayback('ani:1', 'show-a', ok: false);
      await store.clearPlayback('ani:1');
      expect(store.playbackFailures('ani:1'), 0);
    });

    test('sources do not bleed into each other', () async {
      for (var i = 0; i < SourceHealthStore.deadAfterTitles; i++) {
        await store.recordPlayback('ani:1', 'show-$i', ok: false);
      }
      expect(store.playbackLooksDead('ani:1'), isTrue);
      expect(store.playbackLooksDead('mihon:2'), isFalse);
    });
  });

  test('an unknown source reads clean, never throws', () {
    expect(store.playbackFailures('never:seen'), 0);
    expect(store.playbackLooksDead('never:seen'), isFalse);
  });
}
