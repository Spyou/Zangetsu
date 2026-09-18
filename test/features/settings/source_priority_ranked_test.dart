import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/features/settings/source_priority_screen.dart';

void main() {
  // Locks the copy rule the screen's `_reasonFor` delegates to: dead beats a
  // good history, an unused source says so, everything else states its play
  // count. Asserts against the real `reasonForSource` in lib/, not a copy
  // redefined in the test.
  test('a source with plays says so, an unused one says that instead', () {
    expect(
      reasonForSource(plays: 47, health: SourceHealth.ok),
      'played 47 times',
    );
    expect(
      reasonForSource(plays: 0, health: SourceHealth.ok),
      'never used yet · trying it out',
    );
    expect(
      reasonForSource(plays: 99, health: SourceHealth.dead),
      "hasn't worked recently",
      reason: 'dead beats a good history — it cannot play right now',
    );
  });

  test('a row that is not being tried does not claim it is', () {
    // Below the cut, or narrowed out by language: Auto Resolve will not touch
    // it, so "trying it out" would be a plain untruth on that row.
    expect(
      reasonForSource(plays: 0, health: SourceHealth.ok, tried: false),
      'never used',
    );
    expect(
      reasonForSource(plays: 0, health: SourceHealth.ok),
      'never used yet · trying it out',
      reason: 'inside the cap it really is being tried',
    );
    expect(
      reasonForSource(plays: 0, health: SourceHealth.dead, tried: false),
      "hasn't worked recently",
      reason: 'naming the fault beats "never used" on a broken source',
    );
  });
}
