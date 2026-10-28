import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/home/search_screen.dart';

import '../../support/picker_deps.dart';

const _voiceChannel = MethodChannel('zangetsu/voice_search');
const _micKey = ValueKey('phone-search-voice');

class _FakeSourceRepo implements SourceRepository {
  final queries = <String>[];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  List<({String id, String name})> get loadedSources => const [];

  @override
  String get sourceId => 'fake-source';

  @override
  String displayName(String id) => id;

  @override
  bool hasSource(String id) => false;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  void syncSearchCache() {}

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    queries.add(query);
    return (items: const <MediaItem>[], outcome: SourceOutcome.ok);
  }
}

class _FakeMyListStore implements MyListStore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<MediaItem> all() => const [];

  @override
  bool contains(MediaItem m) => false;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeHealth implements SourceHealthStore {
  @override
  bool isSkippable(String id) => false;

  @override
  SourceHealth statusOf(String id) => SourceHealth.ok;

  @override
  Future<void> record(
    String id,
    SourceOutcome outcome, {
    int? responseMs,
  }) async {}

  @override
  Future<void> clear(String id) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _RecordingHistory extends SearchHistory {
  final added = <String>[];

  @override
  List<String> recent() => const [];

  @override
  Future<void> add(String query) async => added.add(query);

  @override
  Future<void> remove(String query) async {}

  @override
  Future<void> clear() async {}
}

class _FakeProfiles implements ViewerProfileStore {
  _FakeProfiles(this.owner);

  String owner;

  @override
  String get ownerKey => owner;

  @override
  String get activeId => 'viewer';

  @override
  bool get adultMetadataAllowed => true;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory dir;
  late _FakeSourceRepo repo;
  late _RecordingHistory history;
  late bool available;
  late List<String?> listenPrompts;
  late Future<String?> Function(String? prompt) onListen;

  Widget harness({String? initialQuery}) => MaterialApp(
    home: BlocProvider<ActiveSourceCubit>.value(
      value: sl<ActiveSourceCubit>(),
      child: SearchScreen(forceSources: true, initialQuery: initialQuery),
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_voice_input');
    Hive.init(dir.path);
    await SearchHistory.init();
    await SearchPrefs.init();
    await SearchSourcePrefs.init();
    await registerPickerDeps();

    repo = _FakeSourceRepo();
    history = _RecordingHistory();
    sl.registerSingleton<SearchHistory>(history);
    sl.registerSingleton<SearchPrefs>(SearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
    sl.registerSingleton<SourceHealthStore>(_FakeHealth());
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<CatalogueRepository>(repo);
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<TitleSuggestionService>(TitleSuggestionService(Dio()));

    available = true;
    listenPrompts = [];
    onListen = (_) async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_voiceChannel, (call) async {
          switch (call.method) {
            case 'isAvailable':
              return available;
            case 'listen':
              listenPrompts.add(call.arguments['prompt'] as String?);
              return onListen(call.arguments['prompt'] as String?);
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_voiceChannel, null);
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('mic shows only when the recogniser is available', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byKey(_micKey), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    available = false;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byKey(_micKey), findsNothing);
  });

  testWidgets('mic stays hidden when the platform has no handler', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_voiceChannel, null);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byKey(_micKey), findsNothing);
  });

  testWidgets('recognised title fills the field and searches exactly once', (
    tester,
  ) async {
    final pending = Completer<String?>();
    onListen = (_) => pending.future;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    repo.queries.clear();

    await tester.tap(find.byKey(_micKey));
    await tester.pump();
    expect(listenPrompts, hasLength(1));
    expect(repo.queries, isEmpty);

    pending.complete('  Naruto  ');
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Naruto');
    expect(
      field.controller!.selection,
      const TextSelection.collapsed(offset: 6),
    );
    expect(history.added, ['Naruto']);
    expect(repo.queries, ['Naruto']);
  });

  testWidgets('blank or cancelled recognition leaves the query untouched', (
    tester,
  ) async {
    await tester.pumpWidget(harness(initialQuery: 'Old query'));
    await tester.pumpAndSettle();
    repo.queries.clear();
    history.added.clear();

    onListen = (_) async => null;
    await tester.tap(find.byKey(_micKey));
    await tester.pumpAndSettle();
    var field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Old query');
    expect(history.added, isEmpty);
    expect(repo.queries, isEmpty);

    onListen = (_) async => '   ';
    await tester.tap(find.byKey(_micKey));
    await tester.pumpAndSettle();
    field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Old query');
    expect(history.added, isEmpty);
    expect(repo.queries, isEmpty);
  });

  testWidgets('listening feedback appears and clears after cancellation', (
    tester,
  ) async {
    final pending = Completer<String?>();
    onListen = (_) => pending.future;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_micKey));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(_micKey),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      'Listening…',
    );
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Voice search failed. Please try again.'), findsNothing);
  });

  testWidgets('recognition failure shows a message and preserves the query', (
    tester,
  ) async {
    onListen = (_) async => throw PlatformException(code: 'voice_failed');
    await tester.pumpWidget(harness(initialQuery: 'Bleach'));
    await tester.pumpAndSettle();
    repo.queries.clear();
    await tester.tap(find.byKey(_micKey));
    await tester.pumpAndSettle();
    expect(find.text('Voice search failed. Please try again.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Bleach',
    );
    expect(repo.queries, isEmpty);
    expect(tester.widget<IconButton>(find.byKey(_micKey)).onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('unrecognised speech shows a speak-again message', (
    tester,
  ) async {
    onListen = (_) async => throw PlatformException(code: 'voice_no_match');
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_micKey));
    await tester.pumpAndSettle();
    expect(
      find.text('Couldn’t hear a title. Please try speaking again.'),
      findsOneWidget,
    );
    expect(repo.queries, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('repeated mic taps while listening start only one recogniser', (
    tester,
  ) async {
    final pending = Completer<String?>();
    onListen = (_) => pending.future;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    repo.queries.clear();

    await tester.tap(find.byKey(_micKey));
    await tester.pump();
    await tester.tap(find.byKey(_micKey));
    await tester.pump();
    expect(listenPrompts, hasLength(1));

    pending.complete('Naruto');
    await tester.pumpAndSettle();
    expect(history.added, ['Naruto']);
    expect(repo.queries, ['Naruto']);
  });

  testWidgets('a result arriving after the screen is gone is discarded', (
    tester,
  ) async {
    final pending = Completer<String?>();
    onListen = (_) => pending.future;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    repo.queries.clear();

    await tester.tap(find.byKey(_micKey));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete('Naruto');
    await tester.pumpAndSettle();
    expect(history.added, isEmpty);
    expect(repo.queries, isEmpty);
  });

  testWidgets('a result is discarded when the search context changed', (
    tester,
  ) async {
    final profiles = _FakeProfiles('owner-a');
    sl.registerSingleton<ViewerProfileStore>(profiles);
    final pending = Completer<String?>();
    onListen = (_) => pending.future;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    repo.queries.clear();
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;

    await tester.tap(find.byKey(_micKey));
    await tester.pump();
    profiles.owner = 'owner-b';
    pending.complete('Naruto');
    await tester.pumpAndSettle();

    expect(controller.text, isEmpty);
    expect(history.added, isEmpty);
    expect(repo.queries, isEmpty);
  });
}
