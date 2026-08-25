import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/home/home_screen_tv.dart';

void main() {
  const section = HomeSection(
    title: 'Trending Now',
    items: [
      MediaItem(
        id: '1',
        title: 'Frieren',
        url: 'u1',
        type: ProviderType.anime,
        sourceId: 's',
      ),
    ],
  );

  testWidgets('poster rail shows the section title and item titles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TvRail(section: section, onTap: (_) {})),
      ),
    );
    await tester.pump();
    expect(find.text('Trending Now'), findsOneWidget);
    expect(find.text('Frieren'), findsWidgets); // title now rendered below the poster
  });

  testWidgets(
    'poster rail wires onLongPress onto the card TvFocusable so held OK works',
    (tester) async {
      MediaItem? longPressed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvRail(
              section: section,
              onTap: (_) {},
              onLongPress: (item) => longPressed = item,
            ),
          ),
        ),
      );
      await tester.pump();

      // First focusable is the poster card; See all (if present) is last.
      final poster = tester
          .widgetList<TvFocusable>(find.byType(TvFocusable))
          .first;
      expect(poster.onLongPress, isNotNull);
      poster.onLongPress!();
      expect(longPressed?.title, 'Frieren');
    },
  );
}
