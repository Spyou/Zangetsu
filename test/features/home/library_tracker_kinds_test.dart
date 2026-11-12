import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/tracker/mangabaka_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/features/home/library_filter.dart';

class _Tracker implements Tracker {
  _Tracker({this.supportsReading = true});
  @override
  final bool supportsReading;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MangaBaka extends _Tracker implements MangaBakaService {}

void main() {
  test('Zangetsu List keeps all categories', () {
    expect(libraryKindsForTracker(null), ContentMode.values);
  });
  test('MangaBaka hides streaming and defaults to manga', () {
    final tracker = _MangaBaka();
    expect(libraryKindsForTracker(tracker), [
      ContentMode.manga,
      ContentMode.novel,
    ]);
    expect(
      libraryKindForTracker(tracker, ContentMode.anime),
      ContentMode.manga,
    );
    expect(
      libraryKindForTracker(tracker, ContentMode.novel),
      ContentMode.novel,
    );
  });
  test('video-only trackers hide reading categories', () {
    final tracker = _Tracker(supportsReading: false);
    expect(libraryKindsForTracker(tracker), [ContentMode.anime]);
    expect(
      libraryKindForTracker(tracker, ContentMode.manga),
      ContentMode.anime,
    );
  });
  test('mixed trackers preserve every category and the selected mode', () {
    final tracker = _Tracker();
    expect(libraryKindsForTracker(tracker), ContentMode.values);
    for (final mode in ContentMode.values) {
      expect(libraryKindForTracker(tracker, mode), mode);
    }
  });
}
