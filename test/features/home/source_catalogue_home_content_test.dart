import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/core/stremio/stremio_provider.dart';
import 'package:watch_app/core/stremio/stremio_home_cache.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
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

  bool empty = false;
  Completer<List<HomeSection>>? nextHome;

  final homeCalls = <({String? sourceId, String category})>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    homeCalls.add((sourceId: sourceId, category: category));
    if (nextHome != null) return nextHome!.future;
    if (empty) return [];
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

class _NotifyingStremioManager extends StremioManager {
  void changed() => notifyListeners();
}

class _TestCubit extends Cubit<int> {
  _TestCubit() : super(0);
}

class _ProgressiveProvider extends StremioProvider {
  _ProgressiveProvider() : super(StremioManager());

  final requests =
      <
        ({
          Completer<List<HomeSection>> result,
          void Function(List<HomeSection>)? report,
          bool forceRefresh,
          void Function(String)? failure,
        })
      >[];

  @override
  Future<List<HomeSection>> getHome({
    String category = 'sub',
    void Function(List<HomeSection>)? onSections,
    bool forceRefresh = false,
    void Function(String)? onFailure,
  }) {
    final result = Completer<List<HomeSection>>();
    requests.add((
      result: result,
      report: onSections,
      forceRefresh: forceRefresh,
      failure: onFailure,
    ));
    return result.future;
  }
}

class _DelayedHomeCache extends StremioHomeCache {
  final result = Completer<List<HomeSection>?>();
  final written = <List<HomeSection>>[];
  @override
  Future<List<HomeSection>?> read(String scope) => result.future;
  @override
  Future<void> write(String scope, List<HomeSection> sections) async {
    written.add(sections);
  }
}

class _ScopedHomeCache extends StremioHomeCache {
  final reads = <String, Completer<List<HomeSection>?>>{};
  @override
  Future<List<HomeSection>?> read(String scope) =>
      (reads[scope] ??= Completer<List<HomeSection>?>()).future;
  @override
  Future<void> write(String scope, List<HomeSection> sections) async {}
}

class _ProfileContext implements ViewerProfileStore {
  @override
  String ownerKey = 'owner';
  @override
  String activeId = 'first';
  @override
  final contextRevision = ValueNotifier<int>(0);
  @override
  ViewerProfile get activeProfile =>
      ViewerProfile(id: activeId, name: activeId);
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HomeSection _catalogueRow(String id, {String? title}) => HomeSection(
  title: title ?? id,
  more: BrowseMore(
    sourceId: 'stremio',
    kind: 'stremio_catalog',
    categoryId: id,
  ),
  items: [
    MediaItem(
      id: id,
      title: id,
      url: '/$id',
      type: ProviderType.movie,
      sourceId: 'stremio',
    ),
  ],
);

void main() {
  setUp(() async {
    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });
  tearDown(() => sl.reset());

  testWidgets(
    'switching profiles rejects a late cached preview and network result',
    (tester) async {
      final cache = _ScopedHomeCache();
      final provider = _ProgressiveProvider();
      final profiles = _ProfileContext();
      sl.registerSingleton<StremioHomeCache>(cache);
      sl.registerSingleton<StremioProvider>(provider);
      sl.registerSingleton<StremioManager>(_NotifyingStremioManager());
      sl.registerSingleton<ViewerProfileStore>(profiles);
      final repository = _StubSourceRepository(const [
        (id: 'stremio', name: 'Stremio'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceCatalogueHomeContent(
                repository: repository,
                initialSourceId: 'stremio',
                showSourcePicker: false,
                sectionBuilder: (row) => Text(row.title),
              ),
            ),
          ),
        ),
      );
      final firstRead = cache.reads.values.single;
      final firstRequest = provider.requests.single;
      profiles.activeId = 'second';
      profiles.contextRevision.value++;
      await tester.pump();
      expect(cache.reads, hasLength(2));
      firstRead.complete([_catalogueRow('old profile')]);
      firstRequest.result.complete([_catalogueRow('old network')]);
      cache.reads.values.last.complete([_catalogueRow('second profile')]);
      await tester.pump();
      expect(find.text('old profile'), findsNothing);
      expect(find.text('old network'), findsNothing);
      expect(find.text('second profile'), findsOneWidget);
      provider.requests.last.result.complete([
        _catalogueRow('fresh second profile'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('fresh second profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final outcome in ['partial', 'offline', 'abort']) {
    for (final cacheFirst in [true, false]) {
      testWidgets(
        'failed catalogue rows survive $outcome refresh without replacing the snapshot (cache first: $cacheFirst)',
        (tester) async {
          final cache = _DelayedHomeCache();
          final provider = _ProgressiveProvider();
          sl.registerSingleton<StremioHomeCache>(cache);
          sl.registerSingleton<StremioProvider>(provider);
          sl.registerSingleton<StremioManager>(_NotifyingStremioManager());
          final repository = _StubSourceRepository(const [
            (id: 'stremio', name: 'Stremio'),
          ]);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: SourceCatalogueHomeContent(
                    repository: repository,
                    initialSourceId: 'stremio',
                    showSourcePicker: false,
                    sectionBuilder: (row) => Text(row.title),
                  ),
                ),
              ),
            ),
          );
          final cached = [
            _catalogueRow('failed'),
            _catalogueRow('good', title: 'old good'),
            _catalogueRow('now empty'),
          ];
          if (cacheFirst) {
            cache.result.complete(cached);
            await tester.pump();
          }
          final request = provider.requests.single;
          if (outcome == 'abort') {
            request.result.completeError(StateError('addon unavailable'));
          } else {
            for (final row in outcome == 'offline' ? cached : [cached.first]) {
              request.failure?.call(row.more!.categoryId!);
            }
            request.result.complete(
              outcome == 'offline'
                  ? []
                  : [_catalogueRow('good', title: 'fresh good')],
            );
          }
          await tester.pumpAndSettle();
          if (!cacheFirst) {
            cache.result.complete(cached);
            await tester.pumpAndSettle();
          }
          expect(find.text('failed'), findsOneWidget);
          expect(
            find.text('fresh good'),
            outcome == 'partial' ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('old good'),
            outcome == 'partial' ? findsNothing : findsOneWidget,
          );
          expect(
            find.text('now empty'),
            outcome == 'partial' ? findsNothing : findsOneWidget,
          );
          expect(cache.written, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final cacheFirst in [true, false]) {
    testWidgets(
      'saved Stremio rows warm Home and fresh results win (cache first: $cacheFirst)',
      (tester) async {
        final cache = _DelayedHomeCache();
        final provider = _ProgressiveProvider();
        sl.registerSingleton<StremioHomeCache>(cache);
        sl.registerSingleton<StremioProvider>(provider);
        sl.registerSingleton<StremioManager>(_NotifyingStremioManager());
        final repository = _StubSourceRepository(const [
          (id: 'stremio', name: 'Stremio'),
        ]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SourceCatalogueHomeContent(
                  repository: repository,
                  initialSourceId: 'stremio',
                  showSourcePicker: false,
                  sectionBuilder: (row) => Text(row.title),
                ),
              ),
            ),
          ),
        );
        final cached = _catalogueRow('cached');
        final fresh = _catalogueRow('fresh');
        if (cacheFirst) {
          cache.result.complete([cached]);
          await tester.pump();
          expect(find.text('cached'), findsOneWidget);
        }
        provider.requests.single.result.complete([fresh]);
        await tester.pumpAndSettle();
        if (!cacheFirst) {
          cache.result.complete([cached]);
          await tester.pumpAndSettle();
        }
        expect(find.text('fresh'), findsOneWidget);
        expect(find.text('cached'), findsNothing);
        expect(cache.written.single.single.title, 'fresh');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'progressive rows stay ordered and refresh preserves unfinished rows',
    (tester) async {
      final provider = _ProgressiveProvider();
      sl.registerSingleton<StremioProvider>(provider);
      final repository = _StubSourceRepository(const [
        (id: 'stremio', name: 'Stremio'),
      ]);
      final controller = SourceCatalogueHomeController();
      final reported = <List<HomeSection>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceCatalogueHomeContent(
                  sliver: true,
                  repository: repository,
                  initialSourceId: 'stremio',
                  showSourcePicker: false,
                  controller: controller,
                  onSectionsChanged: reported.add,
                  sectionBuilder: (row) =>
                      SizedBox(height: 100, child: Text(row.title)),
                ),
              ],
            ),
          ),
        ),
      );
      final first = _catalogueRow('first');
      final second = _catalogueRow('second');
      final request = provider.requests.single;
      request.report!([second]);
      await tester.pump();
      expect(find.text('second'), findsOneWidget);
      request.report!([first, second]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getTopLeft(find.text('first')).dy,
        lessThan(tester.getTopLeft(find.text('second')).dy),
      );
      request.result.complete([first, second]);
      await tester.pumpAndSettle();
      final refresh = controller.refresh();
      await tester.pump();
      final updated = _catalogueRow('first', title: 'updated first');
      final refreshing = provider.requests.last;
      expect(refreshing.forceRefresh, isTrue);
      refreshing.report!([updated]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('updated first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
      expect(reported.last.first.title, 'first');
      refreshing.result.complete([updated, second]);
      await refresh;
      await tester.pumpAndSettle();
      expect(reported.last.first.title, 'updated first');
      expect(repository.homeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stale progressive callbacks cannot replace another source', (
    tester,
  ) async {
    final provider = _ProgressiveProvider();
    sl.registerSingleton<StremioProvider>(provider);
    final repository = _StubSourceRepository(const [
      (id: 'stremio', name: 'Stremio'),
      (id: 'source-a', name: 'Source A'),
    ]);
    Widget page(String source) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SourceCatalogueHomeContent(
            repository: repository,
            initialSourceId: source,
            showSourcePicker: false,
            sectionBuilder: (row) => Text(row.title),
          ),
        ),
      ),
    );
    await tester.pumpWidget(page('stremio'));
    final request = provider.requests.single;
    request.report!([_catalogueRow('first')]);
    await tester.pump();
    request.report!([_catalogueRow('stale')]);
    await tester.pumpWidget(page('source-a'));
    request.result.complete([_catalogueRow('stale')]);
    await tester.pumpAndSettle();
    expect(find.text('source-a catalogue'), findsOneWidget);
    expect(find.text('stale'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Stremio slivers build only nearby rows and preserve them on Back',
    (tester) async {
      final gate = Completer<List<HomeSection>>();
      final repository = _GatedSourceRepository(const [
        (id: 'stremio', name: 'Stremio'),
      ], gate);
      final built = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceCatalogueHomeContent(
                  sliver: true,
                  repository: repository,
                  initialSourceId: 'stremio',
                  showSourcePicker: false,
                  sectionBuilder: (section) {
                    built.add(section.title);
                    return SizedBox(height: 240, child: Text(section.title));
                  },
                ),
              ],
            ),
          ),
        ),
      );
      gate.complete([
        for (var i = 0; i < 100; i++)
          HomeSection(
            title: 'Catalogue $i',
            more: BrowseMore(
              sourceId: 'stremio',
              kind: 'stremio_catalog',
              categoryId: '$i',
            ),
            items: [
              MediaItem(
                id: '$i',
                title: 'Title $i',
                url: '/$i',
                type: ProviderType.movie,
                sourceId: 'stremio',
              ),
            ],
          ),
      ]);
      await tester.pumpAndSettle();
      expect(built.length, lessThan(10));
      expect(find.text('Catalogue 99'), findsNothing);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final oldCalls = Set<String>.from(built);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Detail')),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(built, oldCalls);
      expect(find.text('Catalogue 0'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(built.length, greaterThan(oldCalls.length));
      expect(built.length, lessThan(20));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('other source catalogues also build only nearby rows', (
    tester,
  ) async {
    final gate = Completer<List<HomeSection>>();
    final repository = _GatedSourceRepository(const [
      (id: 'ani:source-a', name: 'Source A'),
    ], gate);
    final built = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SourceCatalogueHomeContent(
                sliver: true,
                repository: repository,
                initialSourceId: 'ani:source-a',
                showSourcePicker: false,
                sectionBuilder: (section) {
                  built.add(section.title);
                  return SizedBox(height: 240, child: Text(section.title));
                },
              ),
            ],
          ),
        ),
      ),
    );
    gate.complete([
      for (var i = 0; i < 100; i++)
        HomeSection(
          title: 'Row $i',
          more: BrowseMore(
            sourceId: 'ani:source-a',
            kind: 'ani_popular',
            categoryId: '$i',
          ),
          items: [
            MediaItem(
              id: '$i',
              title: '$i',
              url: '/$i',
              type: ProviderType.anime,
              sourceId: 'ani:source-a',
            ),
          ],
        ),
    ]);
    await tester.pumpAndSettle();
    expect(built.length, lessThan(10));
    expect(find.text('Row 0'), findsOneWidget);
    expect(find.text('Row 99'), findsNothing);
  });

  for (final hasSource in [true, false]) {
    testWidgets(
      'source catalogue excludes Stremio fallback (source: $hasSource)',
      (tester) async {
        final repository = _StubSourceRepository([
          (id: 'stremio', name: 'Stremio'),
          if (hasSource) (id: 'source-a', name: 'Source A'),
        ]);
        final active = ActiveSourceCubit()..setSource('stremio');
        sl.registerSingleton<ActiveSourceCubit>(active);
        addTearDown(active.close);
        final selected = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SourceCatalogueHomeContent(
                  repository: repository,
                  onSourceSelected: selected.add,
                  showSourcePicker: false,
                  sectionBuilder: (section) => Text(section.title),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(selected, hasSource ? ['source-a'] : isEmpty);
        expect(
          repository.homeCalls.any((call) => call.sourceId == 'stremio'),
          isFalse,
        );
      },
    );
  }

  testWidgets('missing Stremio addons never select another installed source', (
    tester,
  ) async {
    final repository = _StubSourceRepository(const [
      (id: 'source-a', name: 'Source A'),
    ]);
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceCatalogueHomeContent(
            repository: repository,
            initialSourceId: 'stremio',
            showSourcePicker: false,
            onSourceSelected: selected.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.homeCalls, isEmpty);
    expect(selected, everyElement('stremio'));
    expect(find.text('No addons added'), findsOneWidget);
    expect(find.text('Add addons'), findsOneWidget);
  });

  testWidgets('explicit Stremio catalogue cannot fall back to a manga source', (
    tester,
  ) async {
    final repository = _StubSourceRepository(const [
      (id: 'mihon:one', name: 'Manga Source'),
      (id: 'stremio', name: 'Stremio'),
    ]);
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SourceCatalogueHomeContent(
              repository: repository,
              initialSourceId: 'stremio',
              mode: ContentMode.manga,
              showSourcePicker: false,
              onSourceSelected: selected.add,
              sectionBuilder: (section) => Text(section.title),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, ['stremio']);
    expect(repository.homeCalls.single.sourceId, 'stremio');
  });

  testWidgets('adding and removing addons keeps Stremio selected', (
    tester,
  ) async {
    final manager = _NotifyingStremioManager();
    sl.registerSingleton<StremioManager>(manager);
    final sources = <({String id, String name})>[
      (id: 'source-a', name: 'Source A'),
    ];
    final repository = _StubSourceRepository(sources);
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SourceCatalogueHomeContent(
              repository: repository,
              initialSourceId: 'stremio',
              showSourcePicker: false,
              onSourceSelected: selected.add,
              sectionBuilder: (section) => Text(section.title),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No addons added'), findsOneWidget);
    sources.add((id: 'stremio', name: 'Stremio'));
    manager.changed();
    await tester.pumpAndSettle();
    expect(find.text('stremio catalogue'), findsOneWidget);
    sources.removeWhere((s) => s.id == 'stremio');
    manager.changed();
    await tester.pumpAndSettle();
    expect(find.text('No addons added'), findsOneWidget);
    expect(find.text('stremio catalogue'), findsNothing);
    expect(selected, everyElement('stremio'));
    expect(repository.homeCalls.map((call) => call.sourceId), ['stremio']);
  });

  testWidgets('Stremio refresh keeps the current hero until results arrive', (
    tester,
  ) async {
    final repository = _StubSourceRepository(const [
      (id: 'stremio', name: 'Stremio'),
    ]);
    final controller = SourceCatalogueHomeController();
    final reported = <List<HomeSection>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SourceCatalogueHomeContent(
              repository: repository,
              controller: controller,
              initialSourceId: 'stremio',
              showSourcePicker: false,
              onSectionsChanged: reported.add,
              sectionBuilder: (section) => Text(section.title),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reported.last.single.title, 'stremio catalogue');
    repository.nextHome = Completer<List<HomeSection>>();
    final refresh = controller.refresh();
    await tester.pump();
    expect(reported.last.single.title, 'stremio catalogue');
    expect(find.text('stremio catalogue'), findsOneWidget);
    repository.nextHome!.complete(const []);
    await refresh;
    await tester.pumpAndSettle();
    expect(reported.last, isEmpty);
    expect(find.text('stremio catalogue'), findsNothing);
  });

  testWidgets('same-named Stremio rows all render in catalogue order', (
    tester,
  ) async {
    final gate = Completer<List<HomeSection>>();
    final repository = _GatedSourceRepository(const [
      (id: 'stremio', name: 'Stremio'),
    ], gate);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SourceCatalogueHomeContent(
              repository: repository,
              initialSourceId: 'stremio',
              showSourcePicker: false,
              sectionBuilder: (section) =>
                  Text('${section.title}: ${section.items.single.id}'),
            ),
          ),
        ),
      ),
    );
    gate.complete([
      for (final addon in ['first', 'second'])
        HomeSection(
          title: 'Popular',
          more: const BrowseMore(sourceId: 'stremio', kind: 'stremio_catalog'),
          items: [
            MediaItem(
              id: addon,
              title: addon,
              url: '/$addon',
              type: ProviderType.movie,
              sourceId: 'stremio',
            ),
          ],
        ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Popular: first'), findsOneWidget);
    expect(find.text('Popular: second'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Popular: first')).dy,
      lessThan(tester.getTopLeft(find.text('Popular: second')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'Stremio catalogue retains addon ownership without metadata matching',
    () async {
      const item = MediaItem(
        id: 'series:imdb:tt123',
        title: 'Series',
        url: 'stremio://ref?v=1&i=cinemeta&t=series&m=tt123',
        type: ProviderType.movie,
        sourceId: 'stremio',
      );
      expect(await sourceCatalogueTargetFor(item), same(item));
    },
  );

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

  testWidgets('Stremio addon changes do not reload another provider', (
    tester,
  ) async {
    final manager = _NotifyingStremioManager();
    sl.registerSingleton<StremioManager>(manager);
    addTearDown(manager.dispose);
    final repository = _StubSourceRepository(const [
      (id: 'source-a', name: 'Source A'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SourceCatalogueHomeContent(
              repository: repository,
              initialSourceId: 'source-a',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    manager.changed();
    await tester.pumpAndSettle();
    expect(repository.homeCalls, hasLength(1));
    expect(find.text('source-a catalogue'), findsOneWidget);
  });

  testWidgets(
    'Stremio addon changes remove old rows and update the hero immediately',
    (tester) async {
      final manager = _NotifyingStremioManager();
      sl.registerSingleton<StremioManager>(manager);
      addTearDown(manager.dispose);
      final repository = _StubSourceRepository(const [
        (id: 'stremio', name: 'Stremio'),
      ]);
      final reported = <List<HomeSection>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceCatalogueHomeContent(
                repository: repository,
                initialSourceId: 'stremio',
                onSectionsChanged: reported.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('stremio catalogue'), findsOneWidget);
      repository.empty = true;
      manager.changed();
      await tester.pumpAndSettle();
      expect(repository.homeCalls, hasLength(2));
      expect(find.text('stremio catalogue'), findsNothing);
      expect(reported.last, isEmpty);
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
