import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/home/home_screen_tv.dart';

// ── Minimal fake ──────────────────────────────────────────────────────────────

/// Stub [SourceRepository] whose [home] returns the provided sections.
/// All other methods are noSuchMethod-guarded — they throw if called.
class _StubSourceRepository implements SourceRepository {
  const _StubSourceRepository(this._sections);

  final List<HomeSection> _sections;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => _sections;

  @override
  String displayName(String id) => id;

  @override
  String get sourceId => 'test';

  @override
  List<({String id, String name})> get loadedSources => const [];

  @override
  bool hasSource(String id) => false;
}

/// Fake [AuthCubit] with the default (logged-out) state — Continue Watching is
/// login-gated, so this keeps the rail hidden and avoids needing WatchHistory.
class _FakeAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _FakeAuthCubit() : super(const AuthState());
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget _homeApp(HomeCubit cubit) => MultiBlocProvider(
  providers: [
    BlocProvider<HomeCubit>.value(value: cubit),
    BlocProvider<AuthCubit>.value(value: _FakeAuthCubit()),
    BlocProvider<ActiveSourceCubit>.value(value: ActiveSourceCubit()),
  ],
  child: const MaterialApp(home: HomeScreenTv()),
);

// ── Test ──────────────────────────────────────────────────────────────────────

void main() {
  // Two items in one section — enough to verify hero + rail rendering.
  const testItems = [
    MediaItem(
      id: '1',
      title: 'Anime One',
      url: '/1',
      type: ProviderType.anime,
      sourceId: 'test',
    ),
    MediaItem(
      id: '2',
      title: 'Anime Two',
      url: '/2',
      type: ProviderType.anime,
      sourceId: 'test',
    ),
  ];

  late HomeCubit cubit;

  setUp(() async {
    final sections = [
      const HomeSection(title: 'Trending Now', items: testItems),
    ];
    final repo = _StubSourceRepository(sections);
    cubit = HomeCubit(repo);
    if (sl.isRegistered<CatalogueRepository>()) {
      sl.unregister<CatalogueRepository>();
    }
    sl.registerSingleton<CatalogueRepository>(repo);
    // Load populates the cubit state before the widget is pumped.
    await cubit.load();
  });

  tearDown(() => cubit.close());

  testWidgets(
    'HomeScreenTv renders rail items and the first focusable has autofocus',
    (tester) async {
      await tester.pumpWidget(_homeApp(cubit));
      await tester.pumpAndSettle();

      // Hero title + poster card title both contain 'Anime One'.
      expect(find.text('Anime One'), findsWidgets);
      // 'Anime Two' appears only in the rail poster card.
      expect(find.text('Anime Two'), findsOneWidget);

      // At least the hero buttons + rail cards are wrapped in TvFocusable.
      final focusables = tester
          .widgetList<TvFocusable>(find.byType(TvFocusable))
          .toList();
      expect(focusables, isNotEmpty);

      // The very first TvFocusable (hero Play button) carries autofocus=true.
      expect(focusables.first.autofocus, isTrue);

      // Poster rail cards must wire held-OK long-press (info sheet). Without
      // this, TvFocusable treats OK as an immediate tap and long-hold is dead.
      final poster = focusables.firstWhere(
        (f) => f.semanticLabel == 'Anime Two',
      );
      expect(poster.onLongPress, isNotNull);
    },
  );

  testWidgets(
    'HomeScreenTv exposes semantics labels for hero buttons, See all and '
    'poster rail items — with no duplicate-text nodes',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_homeApp(cubit));
      await tester.pumpAndSettle();

      // Hero Play / My List / Info buttons each carry their visible label,
      // and read as a focusable button with a tap action. Play autofocuses.
      // The focus action comes from the framework for anything focusable —
      // matchesSemantics asserts every action it isn't told about is absent,
      // so it has to be named here or the whole matcher fails.
      for (final label in ['Play', 'My List', 'Info']) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          matchesSemantics(
            label: label,
            isButton: true,
            isFocusable: true,
            isFocused: label == 'Play',
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
      }

      // Rail poster: the focusable announces the title, and the sibling
      // title Text below it is excluded — only ONE node carries 'Anime Two'
      // (it doesn't collide with the hero's title, which shows 'Anime One').
      expect(
        tester.getSemantics(find.bySemanticsLabel('Anime Two')),
        matchesSemantics(
          label: 'Anime Two',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasLongPressAction: true,
          hasFocusAction: true,
        ),
      );

      // Trailing "See all" card.
      expect(find.bySemanticsLabel('See all'), findsOneWidget);

      handle.dispose();
    },
  );

  testWidgets('TV home mounts both catalogues offstage when both are cached', (
    tester,
  ) async {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));

    const movieItems = [
      MediaItem(
        id: 'm1',
        title: 'Movie One',
        url: '/m1',
        type: ProviderType.movie,
        sourceId: 'test',
      ),
    ];
    cubit.rememberStreamKindRows(StreamKind.anime, [
      const HomeSection(title: 'Trending Now', items: testItems),
    ]);
    cubit.rememberStreamKindRows(StreamKind.movie, [
      const HomeSection(title: 'Trending Movies', items: movieItems),
    ]);

    await tester.pumpWidget(_homeApp(cubit));
    await tester.pump();

    expect(find.byKey(const ValueKey('tv-home-dual-catalog')), findsOneWidget);
    expect(find.byType(IndexedStack), findsNothing);
    expect(find.text('Anime One'), findsWidgets);
    expect(
      find.text('Movie One', skipOffstage: false),
      findsWidgets,
      reason: 'the inactive Movie/TV catalogue must stay mounted offstage',
    );
  });
}
