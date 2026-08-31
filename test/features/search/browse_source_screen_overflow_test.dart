// Task 15: the browse-source screen's overflow menu (source settings, solve
// Cloudflare, open in browser). Source ids stay `mihon:`-prefixed throughout
// so `sourceTypeOf`/`ecosystemOf` (read by the identity header on every
// build) never fall through to a GetIt-registered registry this test doesn't
// set up — see source_switcher.dart's "no GetIt lookup needed" comment on
// that prefix.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/search/browse_source_screen.dart';

class _FakeRepo implements SourceRepository {
  _FakeRepo({this.baseUrls = const {}});
  final Map<String, String> baseUrls;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async =>
      const [];

  @override
  String baseUrlFor(String sourceId) => baseUrls[sourceId] ?? '';

  // The overflow menu's solve action resolves its target through this
  // instead of baseUrlFor directly (Task 23) — this fake has no CfSolveNeeded
  // flags or CloudStream plugin to prefer, so it degrades to baseUrlFor.
  @override
  Future<String?> cfSolveTargetFor(String sourceId) async {
    final u = baseUrlFor(sourceId);
    return u.isEmpty ? null : u;
  }

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String? languageFor(String sourceId) => null;
}

void main() {
  const mihonChannel = MethodChannel('zangetsu/mihon');
  final mihonCalls = <MethodCall>[];

  Widget harness(Widget child) => MaterialApp(home: child);

  setUp(() {
    mihonCalls.clear();
    sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit(fallback: 'ani:1'));
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mihonChannel, null);
    await sl<ActiveSourceCubit>().close();
    await sl.reset();
  });

  testWidgets('every entry shows when settings and a base url both apply', (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mihonChannel, (call) async {
      mihonCalls.add(call);
      if (call.method == 'hasSourceSettings') return true;
      return null;
    });
    sl.registerSingleton<SourceRepository>(
      _FakeRepo(baseUrls: {'mihon:1': 'https://example.test'}),
    );

    await t.pumpWidget(
        harness(const BrowseSourceScreen(sourceId: 'mihon:1', title: 'MangaDex')));
    await t.pumpAndSettle();

    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pumpAndSettle();

    expect(find.text('Source settings'), findsOneWidget);
    expect(find.text('Solve Cloudflare'), findsOneWidget);
    expect(find.text('Open source site'), findsOneWidget);
  });

  // The menu is no longer conditional: "Source domain" is always offered,
  // because it exists precisely for the case where the reported domain is
  // wrong or missing and so cannot gate on having one.
  testWidgets('a source with no other action still offers Source domain',
      (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mihonChannel, (call) async {
      mihonCalls.add(call);
      if (call.method == 'hasSourceSettings') return false;
      return null;
    });
    sl.registerSingleton<SourceRepository>(_FakeRepo()); // no base url anywhere

    await t.pumpWidget(
        harness(const BrowseSourceScreen(sourceId: 'mihon:2', title: 'No Actions')));
    await t.pumpAndSettle();

    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pumpAndSettle();
    expect(find.text('Source domain'), findsOneWidget);
    expect(find.text('Solve Cloudflare'), findsNothing);
    expect(find.text('Open source site'), findsNothing);
  });

  testWidgets('tapping an overflow entry does not change the active source',
      (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mihonChannel, (call) async {
      mihonCalls.add(call);
      if (call.method == 'hasSourceSettings') return true;
      return null;
    });
    sl.registerSingleton<SourceRepository>(
      _FakeRepo(baseUrls: {'mihon:1': 'https://example.test'}),
    );

    await t.pumpWidget(
        harness(const BrowseSourceScreen(sourceId: 'mihon:1', title: 'MangaDex')));
    await t.pumpAndSettle();

    final before = sl<ActiveSourceCubit>().state;

    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pumpAndSettle();
    await t.tap(find.text('Solve Cloudflare'));
    await t.pumpAndSettle();

    expect(sl<ActiveSourceCubit>().state, before);
    expect(mihonCalls.any((c) => c.method == 'solveCloudflare'), isTrue);

    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pumpAndSettle();
    await t.tap(find.text('Source settings'));
    await t.pumpAndSettle();

    expect(sl<ActiveSourceCubit>().state, before);
    expect(mihonCalls.any((c) => c.method == 'openSourceSettings'), isTrue);
  });
}
