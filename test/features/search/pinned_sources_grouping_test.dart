import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/search/browse_sources_list.dart';

// The Sources tab floats pinned sources into one group at the top, matching
// the source switcher. Pure ordering, so it needs neither Hive nor a widget
// tree — the widget test that tried was fighting the fake clock.

SourceRow _row(String id) => (id: id, label: id, repo: null);

List<(String, List<SourceRow>)> _groups() => [
  ('Anime', [_row('a1'), _row('a2')]),
  ('Movies', [_row('m1')]),
];

void main() {
  test('nothing pinned leaves the groups exactly as they were', () {
    final out = groupWithPinned(_groups(), const [], 'Pinned');
    expect(out.map((g) => g.$1), ['Anime', 'Movies']);
    expect(out.first.$2.map((s) => s.id), ['a1', 'a2']);
  });

  test('a pinned source leads, and leaves its category', () {
    final out = groupWithPinned(_groups(), const ['a2'], 'Pinned');
    expect(out.map((g) => g.$1), ['Pinned', 'Anime', 'Movies']);
    expect(out.first.$2.map((s) => s.id), ['a2']);
    // Listed once, not in both places.
    expect(out[1].$2.map((s) => s.id), ['a1']);
  });

  test('the pinned group crosses categories, in pin order', () {
    // Pin order, not the order the categories happen to be in: the list is
    // the user's own arrangement.
    final out = groupWithPinned(_groups(), const ['m1', 'a1'], 'Pinned');
    expect(out.first.$2.map((s) => s.id), ['m1', 'a1']);
    expect(out.map((g) => g.$1), ['Pinned', 'Anime']);
  });

  test('a category emptied by pinning is dropped, not left as a header', () {
    final out = groupWithPinned(_groups(), const ['m1'], 'Pinned');
    expect(out.map((g) => g.$1), ['Pinned', 'Anime']);
  });

  test('a pinned id that is not on screen is ignored', () {
    // Pins survive an uninstall, and the other kind-tabs hide rows too.
    final out = groupWithPinned(_groups(), const ['gone', 'a1'], 'Pinned');
    expect(out.first.$2.map((s) => s.id), ['a1']);
  });
}
