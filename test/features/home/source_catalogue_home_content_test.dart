import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/ui/row_skeleton.dart';
import 'package:watch_app/features/home/source_catalogue_home_content.dart';

/// A source whose catalogue never answers until the test says so.
class _GatedSourceRepository extends _StubSourceRepository {
  _GatedSourceRepository(super.sources, this.gate);

  final Completer<List<HomeSection>> gate;

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) =>
      gate.future;
}

class _StubSourceRepository implements SourceRepository {
  _StubSourceRepository(this.loadedSources);

  @override
  final List<({String id, String name})> loadedSources;

  final homeCalls = <({String? sourceId, String category})>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    homeCalls.add((sourceId: sourceId, category: category));
    return [
      HomeSection(
        title: '$sourceId catalogue',
        items: [
          MediaItem(
            id: '$sourceId-title',
            title: '$sourceId title',
            url: 'https://example.com/$sourceId-title',
            type: ProviderType.anime,
            sourceId: sourceId ?? '',
          ),
        ],
      ),
    ];
  }

  @override
  String get sourceId => 'metadata';

  @override
  String displayName(String id) {
    for (final source in loadedSources) {
      if (source.id == id) return source.name;
    }
    return id;
  }

  @override
  bool hasSource(String id) => loadedSources.any((s) => s.id == id);
}

class _TestCubit extends Cubit<int> {
  _TestCubit() : super(0);
}

void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });
  tearDown(() => sl.reset());

  test(
    'source catalogue opens matched metadata identity when available',
    () async {
      const source = MediaItem(
        id: 'source-title',
        title: 'Known title',
        url: 'https://source/title',
        type: ProviderType.anime,
        sourceId: 'source-a',
      );
      const metadata = MediaItem(
        id: 'metadata-title',
        title: 'Known title',
        url: 'zm://anime/mal:1',
        type: ProviderType.anime,
        sourceId: 'zm',
      );

      expect(
        await sourceCatalogueTargetFor(source, lookup: (_) async => metadata),
        metadata,
      );
      expect(
        await sourceCatalogueTargetFor(source, lookup: (_) async => null),
        source,
      );
    },
  );

  testWidgets('renders in the Home feed without changing active source', (
    tester,
  ) async {
    final repository = _StubSourceRepository(const [
      (id: 'source-a', name: 'Source A'),
      (id: 'source-b', name: 'Source B'),
    ]);
    final activeSource = ActiveSourceCubit(fallback: 'source-a');
    final activeBefore = activeSource.state;
    sl.registerSingleton<ActiveSourceCubit>(activeSource);
    addTearDown(activeSource.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: SourceCatalogueHomeContent(
                  repository: repository,
                  initialSourceId: 'source-a',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // This content must be embedded in Home, not push a second page of its own.
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(repository.homeCalls, [(sourceId: 'source-a', category: 'sub')]);
    expect(find.text('source-a catalogue'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('source-catalogue-source-picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Source B').last);
    await tester.pumpAndSettle();

    expect(repository.homeCalls.last.sourceId, 'source-b');
    expect(find.text('source-b catalogue'), findsOneWidget);
    expect(activeSource.state, activeBefore);
  });

  testWidgets('reports only the selected source and uses Home row rendering', (
    tester,
  ) async {
    final repository = _StubSourceRepository(const [
      (id: 'source-a', name: 'Source A'),
      (id: 'source-b', name: 'Source B'),
    ]);
    final reported = <List<HomeSection>>[];
    String selected = 'source-a';

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => update(() => selected = 'source-b'),
                  child: const Text('Choose Source B'),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: SourceCatalogueHomeContent(
                      repository: repository,
                      initialSourceId: selected,
                      showSourcePicker: false,
                      onSectionsChanged: reported.add,
                      sectionBuilder: (section) =>
                          Text('Home row: ${section.title}'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home row: source-a catalogue'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-catalogue-source-picker')),
      findsNothing,
    );
    expect(reported.last.single.items.single.sourceId, 'source-a');

    await tester.tap(find.text('Choose Source B'));
    await tester.pumpAndSettle();

    expect(repository.homeCalls.last.sourceId, 'source-b');
    expect(find.text('Home row: source-b catalogue'), findsOneWidget);
    expect(find.text('Home row: source-a catalogue'), findsNothing);
    expect(reported.last.single.items.single.sourceId, 'source-b');
  });

  testWidgets('only offers sources compatible with the current reading mode', (
    tester,
  ) async {
    final repository = _StubSourceRepository(const [
      (id: 'source-a', name: 'Streaming Source'),
      (id: 'mihon:reader', name: 'Manga Source'),
      (id: 'lnr:novel', name: 'Novel Source'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: SourceCatalogueHomeContent(
                  repository: repository,
                  initialSourceId: 'source-a',
                  mode: ContentMode.manga,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.homeCalls.single.sourceId, 'mihon:reader');
    expect(find.text('Manga Source'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('source-catalogue-source-picker')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Novel Source'), findsNothing);
    expect(find.text('Streaming Source'), findsNothing);
  });

  testWidgets('embedded catalogue survives moving between Home slivers', (
    tester,
  ) async {
    final repository = _StubSourceRepository(const [
      (id: 'source-a', name: 'Source A'),
    ]);
    final controller = SourceCatalogueHomeController();
    final modeCubit = _TestCubit();
    addTearDown(modeCubit.close);
    var sourceFirst = false;

    await tester.pumpWidget(
      BlocProvider<Cubit<int>>.value(
        value: modeCubit,
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => sourceFirst = !sourceFirst),
                    child: const Text('Move source catalogue'),
                  ),
                  Expanded(
                    child: CustomScrollView(
                      slivers: sourceFirst
                          ? [
                              SliverToBoxAdapter(
                                child: BlocBuilder<Cubit<int>, int>(
                                  builder: (context, state) =>
                                      SourceCatalogueHomeContent(
                                        repository: repository,
                                        controller: controller,
                                        initialSourceId: 'source-a',
                                      ),
                                ),
                              ),
                              const SliverToBoxAdapter(child: Text('Continue')),
                            ]
                          : [
                              const SliverToBoxAdapter(child: Text('Continue')),
                              SliverToBoxAdapter(
                                child: BlocBuilder<Cubit<int>, int>(
                                  builder: (context, state) =>
                                      SourceCatalogueHomeContent(
                                        repository: repository,
                                        controller: controller,
                                        initialSourceId: 'source-a',
                                      ),
                                ),
                              ),
                            ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Move source catalogue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final callsAfterMove = repository.homeCalls.length;
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(repository.homeCalls, hasLength(callsAfterMove + 1));
  });

  testWidgets('shows shimmer rows, not a spinner, while a source loads', (
    tester,
  ) async {
    final gate = Completer<List<HomeSection>>();
    final repository = _GatedSourceRepository(const [
      (id: 'source-a', name: 'Source A'),
    ], gate);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: SourceCatalogueHomeContent(repository: repository),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RowSkeleton), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    gate.complete([
      HomeSection(
        title: 'Loaded',
        items: [
          MediaItem(
            id: 'x',
            title: 'Loaded title',
            url: 'https://example.com/x',
            type: ProviderType.anime,
            sourceId: 'source-a',
          ),
        ],
      ),
    ]);

    await tester.pump();
    final loadedState = find.byKey(
      const ValueKey('source-catalogue-content-results'),
    );
    expect(loadedState, findsOneWidget);
    final fade = find
        .ancestor(of: loadedState, matching: find.byType(FadeTransition))
        .first;
    expect(tester.widget<FadeTransition>(fade).opacity.value, 0);

    await tester.pump(const Duration(milliseconds: 75));
    final halfwayOpacity = tester.widget<FadeTransition>(fade).opacity.value;
    expect(halfwayOpacity, greaterThan(0));
    expect(halfwayOpacity, lessThan(1));

    await tester.pumpAndSettle();

    expect(find.byType(RowSkeleton), findsNothing);
    expect(find.text('Loaded'), findsOneWidget);
  });
}
