import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/watch_status.dart';

// Task 12 Part B: labelFor() is a reading-aware display mapping beside the
// existing WatchStatusX.label getter — display only, the persisted `.name`
// (and the enum's values) must never change.
void main() {
  group('labelFor', () {
    test('reading:false is a pure passthrough of .label for every status', () {
      for (final s in WatchStatus.values) {
        expect(labelFor(s, reading: false), s.label);
      }
    });

    test('reading:true maps Watching -> Reading', () {
      expect(labelFor(WatchStatus.watching, reading: true), 'Reading');
    });

    test('reading:true maps Plan to Watch -> Plan to Read', () {
      expect(labelFor(WatchStatus.planning, reading: true), 'Plan to Read');
    });

    test('reading:true leaves Completed/Paused/Dropped unchanged', () {
      expect(labelFor(WatchStatus.completed, reading: true), 'Completed');
      expect(labelFor(WatchStatus.paused, reading: true), 'Paused');
      expect(labelFor(WatchStatus.dropped, reading: true), 'Dropped');
    });
  });

  // Guardrail for the hard constraint: cloud sync/backup serialize the enum
  // NAME, not the label — this must never drift.
  test('WatchStatus enum values and the persisted key are untouched', () {
    expect(WatchStatus.values.map((s) => s.name).toList(), [
      'planning',
      'watching',
      'completed',
      'paused',
      'dropped',
    ]);
    for (final s in WatchStatus.values) {
      expect(s.key, s.name);
    }
  });
}
