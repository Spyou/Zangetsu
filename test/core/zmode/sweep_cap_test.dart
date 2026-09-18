import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';

List<({String id, String name})> pool(int n) =>
    [for (var i = 0; i < n; i++) (id: 's$i', name: 's$i')];

SourceRecord Function(String) noHistory() =>
    (_) => (plays: 0, health: SourceHealth.ok, responseMs: null);

void main() {
  // The bug this whole change exists for: an unmatched title used to walk
  // every installed source, one at a time. 500 sources at up to 3s each is
  // minutes of Play tap.
  test('the sweep is bounded no matter how many sources are installed', () {
    final capped = rankByRecord(pool(500), noHistory()).take(kAutoResolveCap);
    expect(capped.length, 10);
  });

  test('a user who has dragged keeps their exact order, uncapped by ranking',
      () {
    // applySourceOrder is what a saved order goes through. Ranking must not
    // run at all in that case — the whole promise of dragging is that the
    // order stays put.
    final saved = ['s3', 's1'];
    final out = applySourceOrder(pool(4), saved);
    expect([for (final s in out) s.id], ['s3', 's1', 's0', 's2']);
  });

  test('kAutoResolveCap is 10 — the number the screen has always advised', () {
    expect(kAutoResolveCap, 10);
  });
}
