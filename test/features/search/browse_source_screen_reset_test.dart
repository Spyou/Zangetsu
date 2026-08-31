// Fix 2: a per-source "Reset source data" action in the browse-source
// overflow menu, for the CloudStream plugins that keep their own reachable
// SharedPreferences + cookies (see source_actions.canResetSourceData). Only
// `cs:` ids offer it — Mihon/Aniyomi have no equivalent store we can reach.
//
// Mirrors browse_source_screen_overflow_test.dart's harness. `cs:` ids need
// a CloudStreamManager registered (sourceTypeOf's identity-header lookup);
// mirrors reading_detail_routing_test.dart's fake for that.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

class _FakeRepo implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async =>
      const [];

  @override
  String baseUrlFor(String sourceId) => '';

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String? languageFor(String sourceId) => null;
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  BaseProvider? get(String sourceId) => null;

  @override
  String? repoNameForSourceId(String sourceId) => null;
}

void main() {
  Widget harness(Widget child) => MaterialApp(home: child);

  setUp(() {
    sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: 'cs:1'));
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<SourceRepository>(_FakeRepo());
  });

  tearDown(() async {
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  testWidgets('a CloudStream source offers Reset in the overflow menu',
      (t) async {
    await t.pumpWidget(
        harness(const BrowseSourceScreen(sourceId: 'cs:AnimePahe', title: 'AnimePahe')));
    await t.pumpAndSettle();

    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pumpAndSettle();

    expect(find.text('Reset'), findsOneWidget);
  });

  testWidgets('a Mihon source has no Reset entry (no overflow at all here)',
      (t) async {
    await t.pumpWidget(
        harness(const BrowseSourceScreen(sourceId: 'mihon:1', title: 'MangaDex')));
    await t.pumpAndSettle();

    // Nothing else applies for this source either (no base url, no
    // settings), so the whole button is absent — Reset included.
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
  });

  testWidgets(
    'tapping Reset asks for confirmation before doing anything',
    (t) async {
      await t.pumpWidget(
          harness(const BrowseSourceScreen(sourceId: 'cs:AnimePahe', title: 'AnimePahe')));
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.more_vert_rounded));
      await t.pumpAndSettle();
      await t.tap(find.text('Reset'));
      await t.pumpAndSettle();

      // The confirm dialog is up — nothing has run yet.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // Cancel: dialog closes, nothing ran (no completion snackbar).
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      // Confirm this time: dialog closes AND the action actually ran.
      await t.tap(find.byIcon(Icons.more_vert_rounded));
      await t.pumpAndSettle();
      await t.tap(find.text('Reset'));
      await t.pumpAndSettle();
      // The dialog's title and its confirm button both read "Reset" — the
      // confirm button is specifically the TextButton.
      await t.tap(find.widgetWithText(TextButton, 'Reset'));
      await t.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
    },
  );
}
