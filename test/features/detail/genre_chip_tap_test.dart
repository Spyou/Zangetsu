// Genre chips are tappable only when a metadata catalogue is behind the page.
// A source reports its genres as plain strings and filters by its own list —
// many sources have no genre filter at all — so the tap would search a
// different library than the one on screen.
//
// The first attempt gated on `detail == null`, which is never true: the record
// is always passed to the tab. This pins the rule to the thing that actually
// distinguishes the two.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

MediaDetail _detail(String sourceId) => MediaDetail(
  id: 'x',
  title: 'T',
  url: 'u',
  type: ProviderType.anime,
  sourceId: sourceId,
  genres: const ['Action'],
);

void main() {
  test('a metadata title is the one a genre tap can answer for', () {
    expect(_detail(ZmodeIds.sourceId).sourceId == ZmodeIds.sourceId, isTrue);
  });

  test('a source title is not', () {
    for (final id in const ['mihon:abc', 'cs:Provider@31', 'ani:1', 'js:x']) {
      expect(
        _detail(id).sourceId == ZmodeIds.sourceId,
        isFalse,
        reason: '$id is a source, and cannot answer a catalogue genre search',
      );
    }
  });

  test('the record is always present, so a null check would never fire', () {
    // Why the first version of this gate did nothing at all.
    expect(_detail('mihon:abc'), isNotNull);
  });
}
