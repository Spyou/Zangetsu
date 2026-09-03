import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';


/// The hero banner is a Trending spotlight — it must keep showing Trending
/// even when Trending isn't the opening row (recently released leads the
/// rows now). Sources with no Trending row (CloudStream feeds, Aniyomi/
/// Mihon Popular) keep the old behaviour: whatever loaded first.
void main() {
  HomeSection section(String title, int id) => HomeSection(
    title: title,
    items: [
      MediaItem(
        id: 'a$id',
        title: 'Item $id',
        url: 'zm://anime/mal:$id',
        type: ProviderType.anime,
        sourceId: 'zm',
      ),
    ],
  );

  test('the banner takes the Trending section, not the opening row', () {
    final state = HomeState(
      sections: [
        section('Recently released', 1),
        section('Trending', 2),
        section('Popular', 3),
      ],
    );
    expect(state.heroItems.single.title, 'Item 2');
  });

  test("Simkl's prefixed Trending titles count as Trending", () {
    final state = HomeState(
      sections: [section('Anticipated', 1), section('Trending series', 2)],
    );
    expect(state.heroItems.single.title, 'Item 2');
  });

  test('a source with no Trending row falls back to the first section', () {
    final state = HomeState(
      sections: [section('Latest', 1), section('Popular', 2)],
    );
    expect(state.heroItems.single.title, 'Item 1');
  });

  test('nothing loaded, nothing to show', () {
    expect(const HomeState().heroItems, isEmpty);
    expect(HomeState(sections: const []).heroItems, isEmpty);
  });
}
