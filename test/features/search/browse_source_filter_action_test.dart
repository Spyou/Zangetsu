// The filter action on the browse-a-source screen. Source filters are an
// extension concept, so the button must appear for Aniyomi/Mihon sources and
// stay away from the ecosystems that have no filter schema at all.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

class _FakeRepo implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];

  @override
  String baseUrlFor(String sourceId) => '';

  @override
  Future<String?> cfSolveTargetFor(String sourceId) async => null;

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String? languageFor(String sourceId) => null;
}

void main() {
  const mihonChannel = MethodChannel('zangetsu/mihon');
  const aniChannel = MethodChannel('zangetsu/aniyomi');

  Widget harness(Widget child) => MaterialApp(home: child);

  setUp(() {
    sl.registerSingleton<ActiveSourceCubit>(
      ActiveSourceCubit(fallback: 'ani:1'),
    );
    sl.registerSingleton<SourceRepository>(_FakeRepo());
    for (final c in const [mihonChannel, aniChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(c, (call) async {
            if (call.method == 'hasSourceSettings') return false;
            return null;
          });
    }
  });

  tearDown(() async {
    for (final c in const [mihonChannel, aniChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(c, null);
    }
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  testWidgets('an Aniyomi source offers filters', (t) async {
    await t.pumpWidget(
      harness(const BrowseSourceScreen(sourceId: 'ani:1', title: 'AllAnime')),
    );
    await t.pumpAndSettle();

    expect(find.byIcon(Icons.filter_list_outlined), findsOneWidget);
    // Nothing applied yet, so there is nothing to clear.
    expect(find.byIcon(Icons.filter_list_off_rounded), findsNothing);
  });

  testWidgets('a Mihon source offers filters', (t) async {
    await t.pumpWidget(
      harness(const BrowseSourceScreen(sourceId: 'mihon:1', title: 'MangaDex')),
    );
    await t.pumpAndSettle();

    expect(find.byIcon(Icons.filter_list_outlined), findsOneWidget);
  });

  testWidgets('an ecosystem without a filter schema offers none', (t) async {
    // Only Aniyomi and Mihon publish a filter schema; elsewhere a filter
    // button could only ever open an empty sheet. Uses an `lnr:` id because
    // CloudStream's would send the identity header into a GetIt registry this
    // test has no reason to stand up (same trap the overflow test documents).
    await t.pumpWidget(
      harness(const BrowseSourceScreen(sourceId: 'lnr:1', title: 'Some Novel')),
    );
    await t.pumpAndSettle();

    expect(find.byIcon(Icons.filter_list_outlined), findsNothing);
  });
}
