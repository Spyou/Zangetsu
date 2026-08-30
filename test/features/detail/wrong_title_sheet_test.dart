import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';

class _Src implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources => [(id: 'allanime', name: 'AllAnime')];
  @override
  bool hasSource(String sourceId) => sourceId == 'allanime';
  @override
  String displayName(String id) => 'AllAnime';
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async => [
    MediaItem(id: 'fma03', title: 'Fullmetal Alchemist (2003)', url: 'https://a/2003', type: ProviderType.anime, sourceId: 'allanime'),
    MediaItem(id: 'fmab', title: 'Fullmetal Alchemist: Brotherhood', url: 'https://a/fmab', type: ProviderType.anime, sourceId: 'allanime'),
  ];
}

void main() {
  late Directory dir;
  const fma = ZCanonical(ZKind.anime, 'mal:5114');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wrongshow');
    Hive.init(dir.path);
    final src = _Src();
    final store = await MatchStore.open();
    sl.registerSingleton<SourceRepository>(src);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: src, store: store, candidates: (_) => src.loadedSources));
  });
  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('MatchLine shows the matched source and opens the sheet', (t) async {
    // MatchLine resolves the match via a real Hive write on first build,
    // which never drains under the pump-driven testWidgets binding without
    // runAsync (same class of issue as mode_switcher_test.dart's setMode).
    // Pre-resolving here means the write happens inside runAsync, and
    // MatchLine's own build-time resolve() just hits the already-saved
    // fast path (a sync Hive read, no write).
    await t.runAsync(
      () => sl<SourceMatcher>().resolve(fma, title: 'Fullmetal Alchemist: Brotherhood'),
    );
    await t.pumpWidget(const MaterialApp(home: Scaffold(
      body: MatchLine(canonical: fma, title: 'Fullmetal Alchemist: Brotherhood'))));
    await t.pumpAndSettle();
    expect(find.textContaining('AllAnime'), findsOneWidget);
    expect(find.text('Wrong title?'), findsOneWidget);
  });

  testWidgets('picking a result pins it', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(
      body: MatchLine(canonical: fma, title: 'Fullmetal Alchemist'))));
    await t.pumpAndSettle();
    await t.tap(find.text('Wrong title?'));
    await t.pumpAndSettle();
    // Picking a result pins it via a real Hive write — see runAsync note above.
    await t.runAsync(() async {
      await t.tap(find.text('Fullmetal Alchemist: Brotherhood'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pumpAndSettle();
    expect(sl<MatchStore>().get(fma)?.showId, 'fmab');
    expect(sl<MatchStore>().get(fma)?.pinned, isTrue);
  });

  testWidgets('no match says so', (t) async {
    await sl.reset();
    Hive.init(dir.path);
    final store = await MatchStore.open();
    final none = _None();
    sl.registerSingleton<SourceRepository>(none);
    sl.registerSingleton<MatchStore>(store);
    sl.registerSingleton<SourceMatcher>(SourceMatcher(
        sources: none, store: store, candidates: (_) => const []));
    await t.pumpWidget(const MaterialApp(home: Scaffold(
      body: MatchLine(canonical: fma, title: 'x'))));
    await t.pumpAndSettle();
    expect(find.text('No source has this yet'), findsOneWidget);
  });
}

class _None implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources => const [];
}
