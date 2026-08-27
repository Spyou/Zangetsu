import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/tv/tv_episode_range_chips.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';

void main() {
  testWidgets('TvEpisodeRangeChips uses accent fill for selected chip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvEpisodeRangeChips(
            count: 2,
            selected: 0,
            labelFor: (i) => i == 0 ? '1–50' : '51–60',
            onSelect: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('1–50'), findsOneWidget);
    expect(find.text('51–60'), findsOneWidget);

    final selected = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('tv-range-0')),
        matching: find.byType(Container),
      ).first,
    );
    final decoration = selected.decoration! as BoxDecoration;
    expect(decoration.color, AppColors.accent);
  });

  testWidgets('TvEpisodeRangeChips wraps chips in TvFocusable box outline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvEpisodeRangeChips(
            count: 2,
            selected: 1,
            labelFor: (i) => i == 0 ? '1–50' : '51–60',
            onSelect: (_) {},
          ),
        ),
      ),
    );

    final chip = tester.widget<TvFocusable>(
      find.byKey(const ValueKey('tv-range-1')),
    );
    expect(chip.variant, TvFocusVariant.box);
  });

  testWidgets('TvEpisodeRangeChips hides when count is 1', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvEpisodeRangeChips(
            count: 1,
            selected: 0,
            labelFor: (_) => '1–50',
            onSelect: (_) {},
          ),
        ),
      ),
    );

    expect(find.byType(TvEpisodeRangeChips), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-range-0')), findsNothing);
  });
}
