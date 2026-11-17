import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_row.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/features/home/home_rows_slivers.dart';

void main() {
  testWidgets(
    'metadata rows are lazy and Continue stays in its saved position',
    (tester) async {
      final built = <String>{};
      final rows = <HomeRow>[
        const ProviderHomeRow(HomeSection(title: 'Before', items: [])),
        const LocalContinueHomeRow(),
        for (var i = 0; i < 100; i++)
          ProviderHomeRow(HomeSection(title: 'Row $i', items: const [])),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: homeRowsSlivers(
                rows,
                continueBuilder: () => const SliverToBoxAdapter(
                  child: SizedBox(height: 100, child: Text('Continue')),
                ),
                rowBuilder: (row) {
                  final title = (row as ProviderHomeRow).section.title;
                  built.add(title);
                  return SizedBox(height: 100, child: Text(title));
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(built.length, lessThan(12));
      expect(
        tester.getTopLeft(find.text('Before')).dy,
        lessThan(tester.getTopLeft(find.text('Continue')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Continue')).dy,
        lessThan(tester.getTopLeft(find.text('Row 0')).dy),
      );
      expect(find.text('Row 99'), findsNothing);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(built.length, greaterThan(10));
      expect(built.length, lessThan(30));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same-named rows retain both entries', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: homeRowsSlivers(
            const [
              ProviderHomeRow(HomeSection(title: 'Same', items: [])),
              ProviderHomeRow(HomeSection(title: 'Same', items: [])),
            ],
            continueBuilder: () => const SliverToBoxAdapter(),
            rowBuilder: (_) => const SizedBox(height: 100, child: Text('Same')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Same'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
