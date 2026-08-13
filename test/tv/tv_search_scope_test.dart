import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/features/home/search_screen_tv.dart';
import 'package:watch_app/features/search/bloc/search_bloc.dart';
import 'package:watch_app/features/search/bloc/search_event.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

// ── Minimal stubs (mirrors test/features/home/search_screen_tv_test.dart) ──

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

class _StubSearchPrefs extends SearchPrefs {
  @override
  String? get contentFilterName => null;
  @override
  String? get audioFilterName => null;
  @override
  String? get sortName => null;
  @override
  String? get genre => null;
  @override
  int? get decade => null;
  @override
  bool get currentSourceOnly => true;
}

class _StubSuggestions extends TitleSuggestionService {
  _StubSuggestions() : super(Dio());

  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async =>
      const [];
}

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

/// Real [SearchBloc] wired to stubs, plus recording of the resulting
/// `currentSourceOnly` on every state change — so the assertion checks real
/// bloc behaviour (via [SearchScopeChanged]), not a hand-rolled event
/// swallower. Starts from `currentSourceOnly: false` (opposite of the "current
/// source" chip's target value) so the bloc's no-op guard for an unchanged
/// value doesn't swallow the state emission we're asserting on.
class _FakeSearchBloc extends SearchBloc {
  _FakeSearchBloc()
      : super(
          repo: _StubSourceRepository(),
          history: _StubSearchHistory(),
          prefs: _StubSearchPrefs(),
          suggestions: _StubSuggestions(),
        ) {
    emit(const SearchState(currentSourceOnly: false));
    stream.listen((s) => scopeEvents.add(s.currentSourceOnly));
  }
  final scopeEvents = <bool>[];
}

void main() {
  testWidgets('scope chip dispatches SearchScopeChanged', (tester) async {
    final bloc = _FakeSearchBloc();
    addTearDown(bloc.close);

    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<SearchBloc>.value(
        value: bloc,
        child: const Scaffold(body: SearchScreenTv()),
      ),
    ));
    await tester.pump();

    final chip = find.byKey(const ValueKey('tv-search-scope-current'));
    expect(chip, findsOneWidget);

    // TvFocusable builds its own Focus widget internally (below itself in the
    // tree, wrapping an AnimatedScale) — Focus.of needs a context INSIDE that
    // Focus, so reach past it via its child before requesting focus.
    final inner = find
        .descendant(of: chip, matching: find.byType(AnimatedScale))
        .first;
    Focus.of(tester.element(inner)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(bloc.scopeEvents, contains(true));
  });
}
