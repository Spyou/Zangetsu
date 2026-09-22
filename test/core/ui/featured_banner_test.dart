import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/ui/featured_banner_panels.dart';

/// The opt-in Panels banner. It replaces the default one wholesale, so what
/// matters is that it shows the title it says it is showing and that its
/// actions fire for THAT title — a banner that plays the wrong show is worse
/// than no banner at all.
///
/// Covers are deliberately null: these assert layout and wiring, and a null
/// cover keeps the test off the network without changing either.
MediaItem _item(String id, String title) => MediaItem(
  id: id,
  title: title,
  url: 'https://example.test/$id',
  type: ProviderType.anime,
  sourceId: 'test',
);

final _three = [
  _item('1', 'First Show'),
  _item('2', 'Second Show'),
  _item('3', 'Third Show'),
];

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('panels', () {
    testWidgets('captions the featured title with its real rank', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          FeaturedBannerPanels(
            items: _three,
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
          ),
        ),
      );
      expect(find.text('First Show'), findsOneWidget);
      expect(find.text('#1 TRENDING'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping a side panel promotes that title', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FeaturedBannerPanels(
            items: _three,
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
          ),
        ),
      );
      // The first side panel is the NEXT title up, so it must land on that one
      // and not simply advance by one from wherever the timer left things.
      await tester.tap(find.byKey(const ValueKey('bannerSidePanel1')));
      await tester.pump();
      expect(find.text('Second Show'), findsOneWidget);
      expect(find.text('#2 TRENDING'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('bannerSidePanel2')));
      await tester.pump();
      // From the second, two along is back round to the first.
      expect(find.text('First Show'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Play fires for the title in the big panel', (tester) async {
      MediaItem? played;
      await tester.pumpWidget(
        _wrap(
          FeaturedBannerPanels(
            items: _three,
            inList: (_) => false,
            onPlay: (m) => played = m,
            onInfo: (_) {},
            onToggleList: (_) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('bannerSidePanel1')));
      await tester.pump();
      // Play is an icon inside the panel now, with no label to find.
      await tester.tap(find.byKey(const ValueKey('bannerPanelPlay')));
      expect(played?.title, 'Second Show');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the controls sit inside the panel, not under it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          FeaturedBannerPanels(
            items: _three,
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
          ),
        ),
      );
      final spreadBottom = tester
          .getRect(find.byKey(const ValueKey('bannerSidePanel2')))
          .bottom;
      final play = tester.getRect(
        find.byKey(const ValueKey('bannerPanelPlay')),
      );
      // Round icon, no word next to it.
      expect(find.text('Play'), findsNothing);
      // Above the bottom of the spread — i.e. on the artwork, which is the
      // whole point of the move. Under the old layout it sat below this line.
      expect(play.center.dy, lessThan(spreadBottom));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a single item draws the big panel alone', (tester) async {
      // Two side panels pointing at the only title would read as a bug.
      await tester.pumpWidget(
        _wrap(
          FeaturedBannerPanels(
            items: [_three.first],
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('bannerSidePanel1')), findsNothing);
      expect(find.text('First Show'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('two items draw one side panel, not the same one twice', (
      tester,
    ) async {
      // There is only one other title, so there is only one panel to fill.
      await tester.pumpWidget(
        _wrap(
          FeaturedBannerPanels(
            items: _three.take(2).toList(),
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('bannerSidePanel1')), findsOneWidget);
      expect(find.byKey(const ValueKey('bannerSidePanel2')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the side panels fill their column', (tester) async {
      // They have nothing inside asking for a width, so a loose constraint
      // collapses them to a hairline and the taps land on the background.
      await tester.pumpWidget(
        _wrap(
          FeaturedBannerPanels(
            items: _three,
            inList: (_) => false,
            onPlay: (_) {},
            onInfo: (_) {},
            onToggleList: (_) {},
          ),
        ),
      );
      final side = tester.getRect(
        find.byKey(const ValueKey('bannerSidePanel1')),
      );
      expect(side.width, greaterThan(80));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
