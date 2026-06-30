import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
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
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async =>
      _sections;

  @override
  String displayName(String id) => id;

  @override
  String get sourceId => 'test';

  @override
  List<({String id, String name})> get loadedSources => const [];

  @override
  bool hasSource(String id) => false;
}

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
    cubit = HomeCubit(_StubSourceRepository(sections));
    // Load populates the cubit state before the widget is pumped.
    await cubit.load();
  });

  tearDown(() => cubit.close());

  testWidgets(
    'HomeScreenTv renders rail items and the first focusable has autofocus',
    (tester) async {
      await tester.pumpWidget(
        BlocProvider<HomeCubit>.value(
          value: cubit,
          child: const MaterialApp(home: HomeScreenTv()),
        ),
      );
      await tester.pumpAndSettle();

      // Hero title + poster card title both contain 'Anime One'.
      expect(find.text('Anime One'), findsWidgets);
      // 'Anime Two' appears only in the rail poster card.
      expect(find.text('Anime Two'), findsOneWidget);

      // At least the hero buttons + rail cards are wrapped in TvFocusable.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables, isNotEmpty);

      // The very first TvFocusable (hero Play button) carries autofocus=true.
      expect(focusables.first.autofocus, isTrue);
    },
  );
}
