// Task 18 Part C: the picker's per-row settings gear and Cloudflare action.
// Harness mirrors wrong_title_sheet_test.dart's fakes; this file only adds
// the per-source-settings channel mock.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
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

void main() {
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
    final src = _Src({
      'ani:1': [MediaItem(id: 'a', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/1', type: ProviderType.anime, sourceId: 'ani:1')],
      'allanime': [MediaItem(id: 'b', title: 'Fullmetal Alchemist (2003)',
          url: 'https://a/2', type: ProviderType.anime, sourceId: 'allanime')],
    });
    final store = await MatchStore.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, candidates: (_) => src.loadedSources));
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(aniChannel, null);
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('a source with settings shows the gear, one without does not', (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();
    expect(find.text('Choose a source'), findsOneWidget);

    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
  });

  testWidgets('tapping the gear opens settings but does not change the selection', (t) async {
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist (2003)'),
    );
    await t.pumpWidget(harness(const MatchLine(
        canonical: fma, title: 'Fullmetal Alchemist (2003)')));
    await t.pumpAndSettle();

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();
    await t.pumpAndSettle();

    final before = sl<MatchStore>().selectedSource(fma);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

    await t.tap(find.byIcon(Icons.tune_rounded));
    await t.pumpAndSettle();

    // The sheet is still open (only a row's own body pops it) and the
    // selection is untouched.
    expect(find.text('Choose a source'), findsOneWidget);
    expect(sl<MatchStore>().selectedSource(fma), before);
    expect(aniCalls.any((c) => c.method == 'openSourceSettings'), isTrue);
  });
}

class _NoopRepo implements CatalogueRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<void> clearHttpCache() async {}
  @override
  Future<MediaDetail> detail(String url, {String category = 'sub', String? sourceId}) async =>
      const MediaDetail(
          id: 'x', title: 'x', url: 'zm://anime/mal:5114', type: ProviderType.anime, sourceId: 'zm');
}
