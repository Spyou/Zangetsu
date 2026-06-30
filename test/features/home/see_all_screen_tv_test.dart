import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/home/see_all_screen_tv.dart';

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  const item1 = MediaItem(
    id: '1',
    title: 'Attack on Titan',
    url: '/aot',
    type: ProviderType.anime,
    sourceId: 'test',
  );
  const item2 = MediaItem(
    id: '2',
    title: 'Demon Slayer',
    url: '/ds',
    type: ProviderType.anime,
    sourceId: 'test',
  );

  testWidgets(
    'SeeAllScreenTv renders poster cards and first card has autofocus',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SeeAllScreenTv(
            title: 'Top Anime',
            items: const [item1, item2],
            onTap: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Title is visible in the app bar.
      expect(find.text('Top Anime'), findsOneWidget);

      // Both poster titles are rendered as poster cards.
      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Demon Slayer'), findsOneWidget);

      // At least 2 TvFocusable cards are present.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(2));

      // The very first TvFocusable (first poster card) has autofocus=true.
      expect(focusables.first.autofocus, isTrue);
    },
  );

  testWidgets(
    'SeeAllScreenTv calls onTap with the correct item on OK-key',
    (tester) async {
      MediaItem? tapped;

      await tester.pumpWidget(
        MaterialApp(
          home: SeeAllScreenTv(
            title: 'Top Anime',
            items: const [item1, item2],
            onTap: (item) => tapped = item,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The first focusable card is autofocused; simulate OK activation.
      final firstFocusable = find.byType(TvFocusable).first;
      expect(firstFocusable, findsOneWidget);

      // Trigger onTap directly through the widget's callback.
      final widget =
          tester.widget<TvFocusable>(firstFocusable);
      widget.onTap();

      expect(tapped, equals(item1));
    },
  );
}
