// Task 18 Part C: the picker's per-row settings gear and Cloudflare action.
// Harness mirrors wrong_title_sheet_test.dart's fakes; this file only adds
// the per-source-settings channel mock.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/picker_deps.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/cf_solve_needed.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';

class _Src implements SourceRepository {
  _Src(this.bySource);
  final Map<String, List<MediaItem>> bySource;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  String baseUrlFor(String id) =>
      id.startsWith('ani:') || id.startsWith('mihon:') || id.startsWith('lnr:')
          ? 'https://example.test'
          : '';
  @override
  List<({String id, String name})> get loadedSources =>
      [for (final id in bySource.keys) (id: id, name: _name(id))];
  static String _name(String id) => id == 'ani:1' ? 'HiAnime' : 'AllAnime';
  @override
  bool hasSource(String sourceId) => bySource.containsKey(sourceId);
  @override
  String displayName(String id) => _name(id);
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      bySource[sourceId] ?? const [];
}

class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;
  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

/// The selector row on the Detail screen carries the same shield/gear pair for
/// the selected source, so a bare byIcon finder matches twice once the sheet is
/// open. Scope to the sheet.
Finder inSheet(Finder f) =>
    find.descendant(of: find.byType(BottomSheet), matching: f);

void main() {
  late ZSourcePrefs prefs;
  late Directory dir;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  const aniChannel = MethodChannel('zangetsu/aniyomi');
  final aniCalls = <MethodCall>[];

  Widget harness(Widget child) => MaterialApp(
    home: Scaffold(
      body: BlocProvider(
        create: (_) => DetailCubit(
          repo: _NoopRepo(),
          url: 'zm://anime/mal:5114',
          prefs: _FakeTitlePrefs(),
        ),
        child: child,
      ),
    ),
  );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    aniCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(aniChannel, (call) async {
      aniCalls.add(call);
      if (call.method == 'hasSourceSettings') {
        // Only the ani:1 row (sourceId 1) actually has settings.
        return (call.arguments as Map)['sourceId'] == 1;
      }
      return null;
    });

    dir = await Directory.systemTemp.createTemp('wrongshow_picker');
    Hive.init(dir.path);
    await registerPickerDeps(aniyomi: [aniSource(id: 1, name: 'HiAnime')]);
    final src = _Src({
      'ani:1': [MediaItem(id: 'a', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/1', type: ProviderType.anime, sourceId: 'ani:1')],
      'allanime': [MediaItem(id: 'b', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2', type: ProviderType.anime, sourceId: 'allanime')],
    });
    final store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<ZSourcePrefs>(prefs);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, prefs: prefs, candidates: (_) => src.loadedSources));
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(aniChannel, null);
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  // The per-source controls live behind one overflow now (three icons on a
  // row that also has to show a name was too many for actions used about
  // twice per source), so every assertion here opens the menu first.
  testWidgets('a source with settings offers it in the overflow, one without does not',
      (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();
    // The shared picker has no title row — its tabs identify it.
    expect(find.text('Movies/Series'), findsOneWidget);

    // allanime is a JS provider with no site and no settings, so it gets no
    // overflow at all rather than an empty menu — ani:1's is the only one.
    expect(inSheet(find.byIcon(Icons.more_vert_rounded)), findsOneWidget);

    await t.tap(inSheet(find.byIcon(Icons.more_vert_rounded)));
    await t.pumpAndSettle();
    expect(find.text('Source settings'), findsOneWidget);
  });

  testWidgets('choosing Source settings opens them but does not change the selection',
      (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();
    await t.pumpAndSettle();

    final before = prefs.get(fma.kind);

    await t.tap(inSheet(find.byIcon(Icons.more_vert_rounded)));
    await t.pumpAndSettle();
    await t.tap(find.text('Source settings'));
    await t.pumpAndSettle();

    // The sheet is still open (only a row's own body pops it) and the
    // selection is untouched.
    // The shared picker has no title row — its tabs identify it.
    expect(find.text('Movies/Series'), findsOneWidget);
    expect(prefs.get(fma.kind), before);
    expect(aniCalls.any((c) => c.method == 'openSourceSettings'), isTrue);
  });

  // Home already routes Mihon, Aniyomi and LNReader challenges through the one
  // solver, so scoping the picker's solve to `mihon:` hid a control that
  // works. The gate is the source's base url: site-backed ecosystems have one,
  // CloudStream/JS items are absolute and have none.
  testWidgets('the Cloudflare entry follows the base url, not the ecosystem',
      (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();

    // ani:1 is site-backed and gets the overflow; allanime is a JS provider
    // with no base url and must not — "nothing to solve against" is the only
    // thing that hides it, not "not currently blocked".
    expect(inSheet(find.byIcon(Icons.more_vert_rounded)), findsOneWidget);
    // The shared picker builds its own row widget, not a ListTile.
    final actionRow = find.ancestor(
      of: inSheet(find.byIcon(Icons.more_vert_rounded)),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: actionRow, matching: find.textContaining('HiAnime')),
      findsOneWidget,
      reason: 'the actions must sit on the site-backed row, not the JS one',
    );
    // Unflagged: nothing on the row but the overflow, and no badge — the
    // badge means a challenge was actually seen.
    expect(inSheet(find.byIcon(Icons.shield_rounded)), findsNothing);
    expect(inSheet(find.byType(Badge)), findsNothing);

    await t.tap(inSheet(find.byIcon(Icons.more_vert_rounded)));
    await t.pumpAndSettle();
    expect(find.text('Solve Cloudflare'), findsOneWidget);
  });

  // Task 20: a source CfSolveNeeded flagged gets a visually distinct control —
  // otherwise there's nothing telling the user THIS one actually needs a
  // solve. It also comes back OUT of the overflow: solving is the one action
  // here you may do repeatedly, and only a flagged source is about to need it.
  testWidgets(
      'a source flagged by CfSolveNeeded gets a distinct badged overflow',
      (t) async {
    CfSolveNeeded.needsSolve(
      'example.test',
      'https://example.test/s?q=x',
      sourceId: 'ani:1',
    );
    addTearDown(() => CfSolveNeeded.clear('example.test'));

    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();

    // The shield is back on the row, badged, one tap from a solve.
    expect(inSheet(find.byIcon(Icons.shield_rounded)), findsOneWidget);
    expect(inSheet(find.byType(Badge)), findsOneWidget);
    // The overflow stays (this source has settings) but is plain, and must
    // not offer the same solve a second time.
    expect(inSheet(find.byIcon(Icons.more_vert_rounded)), findsOneWidget);
    await t.tap(inSheet(find.byIcon(Icons.more_vert_rounded)));
    await t.pumpAndSettle();
    expect(find.text('Solve Cloudflare'), findsNothing);
    expect(find.text('Source settings'), findsOneWidget);
  });
}

class _NoopRepo implements CatalogueRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<void> clearHttpCache() async {}
  @override
  Future<MediaDetail> detail(String url, {String category = 'sub', String? sourceId, void Function(MediaDetail partial)? onPartial}) async =>
      const MediaDetail(
          id: 'x', title: 'x', url: 'zm://anime/mal:5114', type: ProviderType.anime, sourceId: 'zm');
}
