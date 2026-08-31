import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/search/cubit/browse_source_cubit.dart';

class _Repo implements CatalogueRepository {
  _Repo(
    this.sections, {
    this.throws = false,
    this.searchResults = const [],
    this.searchThrows = false,
  });
  final List<HomeSection> sections;
  final bool throws;
  final List<MediaItem> searchResults;
  final bool searchThrows;
  String? askedFor;
  int homeCalls = 0;
  String? searchAskedFor;
  String? lastQuery;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async {
    homeCalls++;
    askedFor = sourceId;
    if (throws) throw StateError('boom');
    return sections;
  }

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
    lastQuery = query;
    searchAskedFor = sourceId;
    if (searchThrows) throw StateError('boom');
    return searchResults;
  }
}

HomeSection _section(String title) => HomeSection(
      title: title,
      items: [_item('1', 'A show')],
    );

MediaItem _item(String id, String title) => MediaItem(
      id: id,
      title: title,
      url: 'https://x/$id',
      type: ProviderType.anime,
      sourceId: 'ani:1',
    );

void main() {
  test('loads the named source, not the active one', () async {
    final repo = _Repo([_section('Latest')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');

    await cubit.load();

    expect(repo.askedFor, 'ani:1');
    expect(cubit.state.sections.single.title, 'Latest');
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.failed, isFalse);
    await cubit.close();
  });

  test('an empty catalogue is empty, not an error', () async {
    final cubit = BrowseSourceCubit(repo: _Repo(const []), sourceId: 'ani:1');
    await cubit.load();
    expect(cubit.state.sections, isEmpty);
    expect(cubit.state.failed, isFalse);
    await cubit.close();
  });

  test('a throwing source surfaces as failed, without crashing', () async {
    final cubit = BrowseSourceCubit(
      repo: _Repo(const [], throws: true),
      sourceId: 'ani:1',
    );
    await cubit.load();
    expect(cubit.state.failed, isTrue);
    expect(cubit.state.loading, isFalse);
    await cubit.close();
  });

  test('a search returns results and they replace the sections', () async {
    final repo = _Repo(
      [_section('Latest')],
      searchResults: [_item('2', 'Found it')],
    );
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.search('found');

    expect(repo.lastQuery, 'found');
    expect(repo.searchAskedFor, 'ani:1');
    expect(cubit.state.searchResults, hasLength(1));
    expect(cubit.state.searchResults!.single.title, 'Found it');
    expect(cubit.state.searching, isFalse);
    expect(cubit.state.searchFailed, isFalse);
    expect(cubit.state.isSearchActive, isTrue);
    await cubit.close();
  });

  test('a search returning nothing is empty, not failed', () async {
    final repo = _Repo([_section('Latest')]);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.search('nothing here');

    expect(cubit.state.searchResults, isEmpty);
    expect(cubit.state.searchFailed, isFalse);
    expect(cubit.state.isSearchActive, isTrue);
    await cubit.close();
  });

  test('a throwing search surfaces as failed', () async {
    final repo = _Repo([_section('Latest')], searchThrows: true);
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();

    await cubit.search('boom');

    expect(cubit.state.searchFailed, isTrue);
    expect(cubit.state.searchResults, isNull);
    expect(cubit.state.searching, isFalse);
    expect(cubit.state.isSearchActive, isTrue);
    await cubit.close();
  });

  test('clearing the query restores the sections without re-fetching home',
      () async {
    final repo = _Repo(
      [_section('Latest')],
      searchResults: [_item('2', 'Found it')],
    );
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();
    expect(repo.homeCalls, 1);

    await cubit.search('found');
    expect(cubit.state.isSearchActive, isTrue);

    cubit.clearSearch();

    expect(cubit.state.isSearchActive, isFalse);
    expect(cubit.state.sections.single.title, 'Latest');
    expect(repo.homeCalls, 1);
    await cubit.close();
  });

  test('searching a blank query clears back to the catalogue', () async {
    final repo = _Repo(
      [_section('Latest')],
      searchResults: [_item('2', 'Found it')],
    );
    final cubit = BrowseSourceCubit(repo: repo, sourceId: 'ani:1');
    await cubit.load();
    await cubit.search('found');

    await cubit.search('   ');

    expect(cubit.state.isSearchActive, isFalse);
    expect(cubit.state.sections.single.title, 'Latest');
    expect(repo.homeCalls, 1);
    await cubit.close();
  });
}
