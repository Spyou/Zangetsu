// A source that answers with nothing used to be a dead end: the screen said
// "no titles" and stopped there, while the two things that actually fix it — a
// retry, or solving the Cloudflare challenge that suppressed the request —
// were buried in an overflow menu with no reason to open it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

class _EmptyRepo implements SourceRepository {
  int homeCalls = 0;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async {
    homeCalls++;
    return const [];
  }

  @override
  String baseUrlFor(String sourceId) => 'https://dead.example';

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
  late _EmptyRepo repo;

  Widget harness(Widget child) => MaterialApp(home: child);

  setUp(() {
    repo = _EmptyRepo();
    sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: 'cs:1'));
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<SourceRepository>(repo);
  });

  tearDown(() async {
    CfSolveNeeded.clear('dead.example');
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  testWidgets('an empty source offers a retry, and it reloads', (t) async {
    await t.pumpWidget(harness(
      const BrowseSourceScreen(sourceId: 'cs:Dead', title: 'Dead'),
    ));
    await t.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    final before = repo.homeCalls;

    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();

    expect(repo.homeCalls, greaterThan(before));
  });

  testWidgets('a Cloudflare-blocked source offers the solve instead',
      (t) async {
    // Retrying a suppressed request just fails again; the challenge is the
    // thing standing in the way, so that is the action to offer.
    CfSolveNeeded.needsSolve(
      'dead.example',
      'https://dead.example',
      sourceId: 'cs:Dead',
    );

    await t.pumpWidget(harness(
      const BrowseSourceScreen(sourceId: 'cs:Dead', title: 'Dead'),
    ));
    await t.pumpAndSettle();

    expect(find.text('Solve Cloudflare'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
