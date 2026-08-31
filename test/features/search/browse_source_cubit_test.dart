import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/search/cubit/browse_source_cubit.dart';

class _Repo implements CatalogueRepository {
  _Repo(this.sections, {this.throws = false});
  final List<HomeSection> sections;
  final bool throws;
  String? askedFor;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async {
    askedFor = sourceId;
    if (throws) throw StateError('boom');
    return sections;
  }
}

HomeSection _section(String title) => HomeSection(
      title: title,
      items: [
        MediaItem(
          id: '1',
          title: 'A show',
          url: 'https://x/1',
          type: ProviderType.anime,
          sourceId: 'ani:1',
        ),
      ],
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
}
