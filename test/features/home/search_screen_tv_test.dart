import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/home/search_screen_tv.dart';
import 'package:watch_app/features/search/bloc/search_bloc.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

// ── Minimal stubs ─────────────────────────────────────────────────────────────

/// [SearchHistory] stub: no Hive dependency, returns empty history.
class _StubSearchHistory extends SearchHistory {
  @override
  List<String> recent() => const [];
  @override
  Future<void> add(String query) async {}
  @override
  Future<void> remove(String query) async {}
  @override
  Future<void> clear() async {}
}

/// [SearchHistory] stub with a mutable list so Clear can be asserted.
class _MutableSearchHistory extends SearchHistory {
  _MutableSearchHistory(this._recent);
  List<String> _recent;

  @override
  List<String> recent() => List.unmodifiable(_recent);

  @override
  Future<void> add(String query) async {}

  @override
  Future<void> remove(String query) async {}

  @override
  Future<void> clear() async {
    _recent = [];
  }
}

/// [SearchPrefs] stub: no Hive dependency, returns safe defaults.
/// Only the getters that [SearchBloc._restoredState] calls are overridden.
class _StubSearchPrefs extends SearchPrefs {
  @override
  String? get contentFilterName => null;
  @override
  String? get audioFilterName => null;
  @override
  String? get statusFilterName => null;
  @override
  String? get sortName => null;
  @override
  String? get genre => null;
  @override
  int? get decade => null;
  @override
  bool get currentSourceOnly => true;
}

/// [TitleSuggestionService] stub: never makes network calls.
class _StubSuggestions extends TitleSuggestionService {
  _StubSuggestions() : super(Dio());

  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async =>
      const [];
}

/// [SourceRepository] stub: implements the class interface.
/// All un-overridden methods are guarded by [noSuchMethod].
class _StubSourceRepository implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  String get sourceId => 'stub';

  @override
  List<({String id, String name})> get loadedSources => const [];

  @override
  String displayName(String id) => id;

  @override
  bool hasSource(String id) => false;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => const [];
}

/// Fake [SearchBloc] that extends the real class (so it satisfies
/// [BlocProvider<SearchBloc>]'s type constraint) but is initialised with stub
/// dependencies and then immediately emits a preset [SearchState].
///
/// All event handlers inherited from [SearchBloc] are registered but never
/// invoked in tests — no events are dispatched — so no real repo/history calls
/// are made.
class _FakeSearchBloc extends SearchBloc {
  _FakeSearchBloc(SearchState targetState)
      : super(
          repo: _StubSourceRepository(),
          history: _StubSearchHistory(),
          prefs: _StubSearchPrefs(),
          suggestions: _StubSuggestions(),
        ) {
    // Override the state set by _restoredState() with the desired test state.
    emit(targetState);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Widget _buildUnderTest(_FakeSearchBloc bloc, {SearchHistory? history}) =>
    BlocProvider<SearchBloc>.value(
      value: bloc,
      child: MaterialApp(home: SearchScreenTv(history: history)),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  const item1 = MediaItem(
    id: '1',
    title: 'Attack on Titan',
    url: '/aot',
    type: ProviderType.anime,
    sourceId: 'test',
  );
  const item2 = MediaItem(
    id: '2',
    title: 'Demon Slayer',
    url: '/ds',
    type: ProviderType.anime,
    sourceId: 'test',
  );

  testWidgets(
    'SearchScreenTv renders an autofocus-capable search field',
    (tester) async {
      final bloc = _FakeSearchBloc(SearchState());
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pump();

      // The TextField for query entry must be present.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(find.byType(TextField), findsOneWidget);
      // autofocus=true so the Android TV keyboard is triggered on first build.
      expect(field.autofocus, isTrue);
    },
  );

  testWidgets(
    'SearchScreenTv shows idle state when bloc is idle',
    (tester) async {
      final bloc =
          _FakeSearchBloc(SearchState(status: SearchStatus.idle));
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pump();

      expect(find.text('Search for something to watch'), findsOneWidget);
      // The scope chips are always visible (2 TvFocusables), but no result
      // cards exist in idle state. Clear history is hidden until recents exist.
      expect(find.byType(TvFocusable), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('tv-search-scope-current')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tv-search-clear-history')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'SearchScreenTv renders result poster cards wrapped in TvFocusable '
    'and the first result card has autofocus',
    (tester) async {
      final group = SourceResultGroup(
        sourceId: 'test',
        sourceName: 'Test Source',
        items: [item1, item2],
        arrivalIndex: 0,
      );
      final bloc = _FakeSearchBloc(
        SearchState(
          status: SearchStatus.success,
          query: 'titan',
          groups: [group],
          sourceFilter: kAllSources,
        ),
      );
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pump();

      // Both titles render as poster cards.
      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Demon Slayer'), findsOneWidget);

      // Each result card is wrapped in TvFocusable (plus the 2 scope chips
      // that render above the results regardless of state).
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(4));

      // The first result card (not the scope chips) carries autofocus=true
      // so D-pad DOWN from the search field lands here immediately.
      final firstCard = focusables.firstWhere((f) => f.autofocus);
      expect(firstCard.key, isNot(const ValueKey('tv-search-scope-current')));
      expect(firstCard.key, isNot(const ValueKey('tv-search-scope-all')));
    },
  );

  testWidgets(
    'SearchScreenTv shows error state when bloc emits error',
    (tester) async {
      final bloc =
          _FakeSearchBloc(SearchState(status: SearchStatus.error));
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pump();

      expect(find.text('Search failed — try again'), findsOneWidget);
    },
  );

  testWidgets(
    'SearchScreenTv shows no-results message on success with empty groups',
    (tester) async {
      final bloc = _FakeSearchBloc(
        SearchState(
          status: SearchStatus.success,
          query: 'xyznotfound',
          groups: [],
        ),
      );
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildUnderTest(bloc));
      await tester.pump();

      expect(find.textContaining('No results for'), findsOneWidget);
    },
  );

  // ── _onFieldKey: arrowDown leaves the field regardless of accessibleNav ───
  //
  // Fire TV / onn falsely report accessibleNavigation=true after the native
  // player with no screen reader running, which used to trap D-pad DOWN inside
  // the field. So _onFieldKey now moves focus down whether the flag is on or
  // off — the screen-reader-ON case mirrors the OFF case. The scope chips
  // ("All sources"/"Current source") render unconditionally below the field,
  // so they're always a valid down-traversal target regardless of search
  // state.

  testWidgets(
    'SearchScreenTv _onFieldKey: arrowDown moves focus out of the field when '
    'a screen reader is OFF (sighted user, original behaviour)',
    (tester) async {
      final bloc = _FakeSearchBloc(SearchState());
      addTearDown(bloc.close);

      await tester.pumpWidget(
        BlocProvider<SearchBloc>.value(
          value: bloc,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: false),
              child: const SearchScreenTv(),
            ),
          ),
        ),
      );
      await tester.pump();

      final fieldNode =
          tester.widget<TextField>(find.byType(TextField)).focusNode!;
      fieldNode.requestFocus();
      await tester.pumpAndSettle();
      expect(tester.binding.focusManager.primaryFocus, same(fieldNode));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(
        tester.binding.focusManager.primaryFocus,
        isNot(same(fieldNode)),
      );
    },
  );

  testWidgets(
    'SearchScreenTv _onFieldKey: arrowDown still moves focus out of the field '
    'when a screen reader is ON (D-pad stays live even when the TV falsely '
    'reports one)',
    (tester) async {
      final bloc = _FakeSearchBloc(SearchState());
      addTearDown(bloc.close);

      await tester.pumpWidget(
        BlocProvider<SearchBloc>.value(
          value: bloc,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: true),
              child: const SearchScreenTv(),
            ),
          ),
        ),
      );
      await tester.pump();

      final fieldNode =
          tester.widget<TextField>(find.byType(TextField)).focusNode!;
      fieldNode.requestFocus();
      await tester.pumpAndSettle();
      expect(tester.binding.focusManager.primaryFocus, same(fieldNode));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(
        tester.binding.focusManager.primaryFocus,
        isNot(same(fieldNode)),
      );
    },
  );

  testWidgets(
    'SearchScreenTv idle lists recent searches and a Clear button',
    (tester) async {
      final bloc =
          _FakeSearchBloc(SearchState(status: SearchStatus.idle));
      addTearDown(bloc.close);
      final history = _MutableSearchHistory(['Naruto', 'One Piece']);

      await tester.pumpWidget(_buildUnderTest(bloc, history: history));
      await tester.pump();

      expect(find.text('Recent searches'), findsOneWidget);
      expect(find.text('Naruto'), findsOneWidget);
      expect(find.text('One Piece'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tv-search-clear-history')),
        findsOneWidget,
      );
      expect(find.text('Search for something to watch'), findsNothing);
    },
  );

  testWidgets(
    'SearchScreenTv Clear wipes recents and returns to the empty idle prompt',
    (tester) async {
      final bloc =
          _FakeSearchBloc(SearchState(status: SearchStatus.idle));
      addTearDown(bloc.close);
      final history = _MutableSearchHistory(['Naruto']);

      await tester.pumpWidget(_buildUnderTest(bloc, history: history));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('tv-search-clear-history')));
      await tester.pump();

      expect(history.recent(), isEmpty);
      expect(find.text('Recent searches'), findsNothing);
      expect(find.byKey(const ValueKey('tv-search-clear-history')), findsNothing);
      expect(find.text('Search for something to watch'), findsOneWidget);
    },
  );
}
