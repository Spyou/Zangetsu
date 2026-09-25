import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/search/meta_filter_dialog_tv.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Holds the value popped from the dialog after Apply / dismiss.
class _Picked {
  MetaFilters? value;
}

Future<_Picked> _openDialog(
  WidgetTester t, {
  MetaFilters current = const MetaFilters(),
  ZKind kind = ZKind.anime,
}) async {
  final picked = _Picked();
  await t.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => t.binding.setSurfaceSize(null));

  await t.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                picked.value = await showMetaFilterDialogTv(ctx, kind, current);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return picked;
}

Future<void> _ok(WidgetTester t) async {
  await t.sendKeyEvent(LogicalKeyboardKey.select);
  await t.pumpAndSettle();
}

Future<void> _openGenres(WidgetTester t) async {
  final genres = find.byKey(const ValueKey('tv-meta-filter-genres'));
  await t.ensureVisible(genres);
  await t.pumpAndSettle();
  await t.tap(genres);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('filter rows are D-pad focusable, not just Apply', (t) async {
    await _openDialog(t);

    expect(find.byKey(const ValueKey('tv-meta-filter-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-meta-filter-sort')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-meta-filter-genres')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-meta-filter-apply')), findsOneWidget);

    final sort = t.widget<TvFocusable>(
      find.descendant(
        of: find.byKey(const ValueKey('tv-meta-filter-sort')),
        matching: find.byType(TvFocusable),
      ),
    );
    expect(sort.autofocus, isTrue);
  });

  testWidgets('genre picker autofocuses the first genre, not Done', (t) async {
    await _openDialog(t);

    await _openGenres(t);

    expect(find.byKey(const ValueKey('tv-genre-picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-genre-Action')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-genre-done')), findsOneWidget);

    final action = t.widget<TvFocusable>(
      find.descendant(
        of: find.byKey(const ValueKey('tv-genre-Action')),
        matching: find.byType(TvFocusable),
      ),
    );
    expect(action.autofocus, isTrue);

    final done = t.widget<TvFocusable>(
      find.byKey(const ValueKey('tv-genre-done')),
    );
    expect(done.autofocus, isFalse);
  });

  testWidgets('D-pad can select a genre then apply it', (t) async {
    final picked = await _openDialog(t);

    await _openGenres(t);

    // First genre (Action) is autofocused — Select toggles it.
    await _ok(t);
    expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('tv-genre-done')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('tv-meta-filter-apply')));
    await t.pumpAndSettle();

    expect(picked.value, isNotNull);
    expect(picked.value!.genres, ['Action']);
  });

  testWidgets('hides the adult genre while 18+ is off', (t) async {
    await _openDialog(t, current: const MetaFilters(adult: false));
    await _openGenres(t);

    expect(find.byKey(ValueKey('tv-genre-$kAdultGenre')), findsNothing);
    expect(find.byKey(const ValueKey('tv-genre-Action')), findsOneWidget);
  });

  testWidgets('offers the adult genre once 18+ is on', (t) async {
    await _openDialog(t, current: const MetaFilters(adult: true));
    await _openGenres(t);

    expect(find.byKey(ValueKey('tv-genre-$kAdultGenre')), findsOneWidget);
  });
}
