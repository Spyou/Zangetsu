import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/parental_guide_service.dart';
import 'package:watch_app/features/player/parental_guide_card.dart';

void main() {
  const warnings = [
    ParentalWarning('Violence', 'Moderate'),
    ParentalWarning('Profanity', 'Mild'),
  ];

  testWidgets('shows the rows, holds, then finishes and reports done', (
    tester,
  ) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ParentalGuideCard(warnings: warnings, onDone: () => done++),
        ),
      ),
    );
    expect(done, 0);
    // Rows are in well before the five-second hold ends.
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Violence', findRichText: true), findsOneWidget);
    expect(find.textContaining('Mild', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(done, 0);
    await tester.pump(const Duration(seconds: 4));
    expect(done, 1);
  });
}
