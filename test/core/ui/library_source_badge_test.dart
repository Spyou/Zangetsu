import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/stremio/stremio_library_badge.dart';
import 'package:watch_app/core/ui/poster_card.dart';

void main() {
  testWidgets('posters have no source badge by default', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 120,
          height: 220,
          child: PosterCard(title: 'Title'),
        ),
      ),
    );

    expect(find.byType(StremioLibraryBadge), findsNothing);
  });

  testWidgets('small right badge keeps the score and poster tap working', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            height: 220,
            child: PosterCard(
              title: 'Title',
              scoreBadge: 80,
              topRightBadge: const StremioLibraryBadge(),
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );

    final badge = find.byType(StremioLibraryBadge);
    expect(tester.getSize(badge), const Size(22, 22));
    expect(find.bySemanticsLabel(RegExp('Stremio')), findsOneWidget);
    expect(find.text('8.0'), findsOneWidget);
    expect(tester.getTopRight(badge).dx, 114);
    expect(tester.getTopRight(badge).dy, 6);
    await tester.tapAt(tester.getCenter(badge));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
