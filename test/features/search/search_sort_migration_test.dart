// SearchSort.rating was removed — it sorted by TITLE while claiming to sort
// by rating (no rating data exists on search results; see the removed enum
// value's own doc comment). A value already persisted from an older build
// must not throw on restore and must not silently keep acting as a sort —
// SearchBloc._restoredState falls back to bestMatch for any name that no
// longer matches an enum value, which 'rating' now is.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/features/search/bloc/search_bloc.dart';
import 'package:watch_app/features/search/bloc/search_state.dart';

/// Fake prefs whose sortName is fixed at construction — models whatever an
/// older build already wrote to the Hive box before this run starts.
class _FakeSearchPrefs extends SearchPrefs {
  _FakeSearchPrefs({this.storedSortName});
  final String? storedSortName;

  @override
  String? get contentFilterName => null;
  @override
  String? get audioFilterName => null;
  @override
  String? get statusFilterName => null;
  @override
  String? get sortName => storedSortName;
  @override
  String? get genre => null;
  @override
  int? get decade => null;
  @override
  bool get currentSourceOnly => true;

  @override
  Future<void> setContentFilterName(String name) async {}
  @override
  Future<void> setAudioFilterName(String name) async {}
  @override
  Future<void> setStatusFilterName(String name) async {}
  @override
  Future<void> setSortName(String name) async {}
  @override
  Future<void> setGenre(String? genre) async {}
  @override
  Future<void> setDecade(int? decade) async {}
  @override
  Future<void> setCurrentSourceOnly(bool value) async {}
}

class _FakeSearchHistory extends SearchHistory {
  @override
  List<String> recent() => [];
  @override
  Future<void> add(String query) async {}
  @override
  Future<void> remove(String query) async {}
  @override
  Future<void> clear() async {}
}

class _FakeSuggestions extends TitleSuggestionService {
  _FakeSuggestions() : super(Dio());
  @override
  Future<List<String>> suggest(String query, {int limit = 8}) async => [];
}

/// Never actually called: the bloc's constructor doesn't touch the repo, it
/// only restores state from prefs.
class _FakeRepo implements SourceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  SearchBloc buildBloc(String? storedSortName) => SearchBloc(
    repo: _FakeRepo(),
    history: _FakeSearchHistory(),
    prefs: _FakeSearchPrefs(storedSortName: storedSortName),
    suggestions: _FakeSuggestions(),
  );

  group('sort restore migration', () {
    test('a value from before the enum removed "rating" falls back to '
        'bestMatch, not a crash', () async {
      final bloc = buildBloc('rating');
      expect(bloc.state.sort, SearchSort.bestMatch);
      await bloc.close();
    });

    test('no stored value defaults to bestMatch', () async {
      final bloc = buildBloc(null);
      expect(bloc.state.sort, SearchSort.bestMatch);
      await bloc.close();
    });

    test('a still-valid stored value restores normally', () async {
      final bloc = buildBloc('titleAsc');
      expect(bloc.state.sort, SearchSort.titleAsc);
      await bloc.close();
    });

    test('SearchSort no longer has a rating value at all', () {
      expect(SearchSort.values.any((s) => s.name == 'rating'), isFalse);
    });
  });
}
