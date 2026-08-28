import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tap_zones.dart';

const topLeft = Offset(0.1, 0.1);
const centre = Offset(0.5, 0.5);
const bottomRight = Offset(0.9, 0.9);

void main() {
  group('paged defaults match how the reader always behaved', () {
    final l = TapZoneLayout.defaultFor(TapZoneLayout.paged);

    test('left goes back, right goes forward, middle opens the controls', () {
      expect(l.actionAt(topLeft), ReaderAction.prevPage);
      expect(l.actionAt(centre), ReaderAction.toggleMenu);
      expect(l.actionAt(bottomRight), ReaderAction.nextPage);
    });

    test('right-to-left mirrors paging only', () {
      expect(l.actionAt(topLeft, rtl: true), ReaderAction.nextPage);
      expect(l.actionAt(bottomRight, rtl: true), ReaderAction.prevPage);
      // The middle is not a paging action, so rtl must leave it alone.
      expect(l.actionAt(centre, rtl: true), ReaderAction.toggleMenu);
    });
  });

  test('webtoon scrolls instead of paging', () {
    // A long strip has no pages to turn — tapping used to do nothing here.
    final l = TapZoneLayout.defaultFor(TapZoneLayout.webtoon);
    expect(l.actionAt(const Offset(0.5, 0.1)), ReaderAction.scrollUp);
    expect(l.actionAt(centre), ReaderAction.toggleMenu);
    expect(l.actionAt(const Offset(0.5, 0.9)), ReaderAction.scrollDown);
    // Scrolling is not mirrored: down is down whichever way you read.
    expect(
      l.actionAt(const Offset(0.5, 0.9), rtl: true),
      ReaderAction.scrollDown,
    );
  });

  test('every reading mode the reader can be in maps to a layout', () {
    // The reader reports 'ltr' | 'rtl' | 'vertical'. 'vertical' falling through
    // to the paged layout was a real bug: left/right zones firing nextPage at a
    // strip that has no pages, so tapping did nothing at all.
    expect(TapZoneLayout.idForReadingMode('ltr'), TapZoneLayout.paged);
    expect(TapZoneLayout.idForReadingMode('rtl'), TapZoneLayout.paged);
    expect(TapZoneLayout.idForReadingMode('vertical'), TapZoneLayout.webtoon);
    // The dormant `readingMode` spellings resolve too, so wiring that key up
    // later can't silently reintroduce the same bug.
    expect(TapZoneLayout.idForReadingMode('webtoon'), TapZoneLayout.webtoon);
    expect(
      TapZoneLayout.idForReadingMode('vertical_paged'),
      TapZoneLayout.webtoon,
    );
    expect(TapZoneLayout.idForReadingMode('nonsense'), TapZoneLayout.paged);
  });

  group('persistence', () {
    test('a customised layout round-trips', () {
      final custom = TapZoneLayout.defaultFor(
        TapZoneLayout.paged,
      ).withZoneAction(0, ReaderAction.prevChapter);
      final back = TapZoneLayout.fromJsonString(
        custom.toJsonString(),
        TapZoneLayout.paged,
      );
      expect(back.actionAt(topLeft), ReaderAction.prevChapter);
      expect(back.actionAt(bottomRight), ReaderAction.nextPage);
    });

    test('corrupt or empty saved data falls back to the default', () {
      // A broken layout would otherwise leave a screen where nothing responds.
      for (final bad in [null, '', 'not json', '{}', '{"zones":[]}']) {
        final l = TapZoneLayout.fromJsonString(bad, TapZoneLayout.paged);
        expect(l.actionAt(topLeft), ReaderAction.prevPage, reason: '$bad');
      }
    });

    test('a zone with no area is dropped, not kept as a dead target', () {
      expect(
        TapZone.fromJson({'l': 0.5, 't': 0, 'r': 0.5, 'b': 1, 'a': 'nextPage'}),
        isNull,
      );
      expect(TapZone.fromJson({'l': 0, 't': 0, 'r': 1}), isNull);
      expect(TapZone.fromJson('nope'), isNull);
    });

    test('an unknown action reads as none instead of throwing', () {
      final z = TapZone.fromJson({
        'l': 0.0,
        't': 0.0,
        'r': 1.0,
        'b': 1.0,
        'a': 'summonCthulhu',
      });
      expect(z, isNotNull);
      expect(z!.action, ReaderAction.none);
    });
  });

  test('overlapping zones resolve to the one on top', () {
    final l = TapZoneLayout(
      id: 'x',
      name: 'x',
      zones: const [
        TapZone(bounds: Rect.fromLTRB(0, 0, 1, 1), action: ReaderAction.none),
        TapZone(
          bounds: Rect.fromLTRB(0, 0, 0.5, 1),
          action: ReaderAction.nextChapter,
        ),
      ],
    );
    expect(l.actionAt(const Offset(0.2, 0.5)), ReaderAction.nextChapter);
    expect(l.actionAt(const Offset(0.8, 0.5)), ReaderAction.none);
  });
}
