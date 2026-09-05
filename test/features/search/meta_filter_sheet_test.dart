// The sheet offers the adult genre only while the 18+ switch is on.
//
// Offering it with the switch off would let you select a genre the query then
// strips out — an empty grid with nothing saying why. The switch sits beside
// this sheet, so following it is both safe and obvious.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/search/meta_filter_sheet.dart';
import 'package:watch_app/l10n/app_localizations.dart';

Future<void> openSheet(
  WidgetTester t, {
  required bool adult,
  ZKind kind = ZKind.anime,
}) async {
  await t.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  showMetaFilterSheet(ctx, kind, MetaFilters(adult: adult)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  // Genres are a nested sheet: the main sheet shows a GENRES cell (the label
  // renders uppercased) which opens the chip picker. Tap through to it.
  await t.tap(find.text('GENRES'));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    // The sheet lists every genre; a chip that never laid out cannot be found.
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(420 * 3, 2200 * 3);
    v.devicePixelRatio = 3;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
  });

  testWidgets('hides the adult genre while 18+ is off', (t) async {
    await openSheet(t, adult: false);
    expect(find.text(kAdultGenre), findsNothing);
    // The rest of the list is untouched.
    expect(find.text('Action'), findsOneWidget);
  });

  testWidgets('offers it once 18+ is on', (t) async {
    await openSheet(t, adult: true);
    expect(find.text(kAdultGenre), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
  });

  testWidgets('never offers it for movie/TV, 18+ or not', (t) async {
    await openSheet(t, adult: true, kind: ZKind.movie);
    // TMDB has no adult genre to filter on — only an include_adult flag.
    expect(find.text(kAdultGenre), findsNothing);
  });
}
