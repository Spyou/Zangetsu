import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  url: 'https://x.test/$id',
  type: ProviderType.anime,
  sourceId: 'ani:1',
);

void main() {
  group('HomeSection.more', () {
    test('defaults to null (non-paginable) when omitted', () {
      final s = HomeSection(title: 'Popular', items: [_item('a')]);
      expect(s.more, isNull);
      expect(s.items, hasLength(1));
    });

    test('carries a BrowseMore descriptor when provided', () {
      const more = BrowseMore(sourceId: 'ani:1', kind: 'ani_popular');
      final s = HomeSection(title: 'Popular', items: [_item('a')], more: more);
      expect(s.more, same(more));
      expect(s.more!.kind, 'ani_popular');
      expect(s.more!.sourceId, 'ani:1');
    });
  });

  group('BrowseMore', () {
    test('categoryId defaults to null for the Aniyomi kinds', () {
      const more = BrowseMore(sourceId: 'ani:1', kind: 'ani_latest');
      expect(more.categoryId, isNull);
    });

    test('packs a CloudStream mainPage category id', () {
      const more = BrowseMore(
        sourceId: 'cs:Foo',
        kind: 'cs_mainpage',
        categoryId: 'Popular https://foo.test/list?p=',
      );
      expect(more.kind, 'cs_mainpage');
      expect(more.categoryId, 'Popular https://foo.test/list?p=');
    });
  });
}
