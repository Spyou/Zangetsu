import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/home/cubit/home_cache.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('home-cache-test');
    Hive.init(dir.path);
    await HomeCache.init();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('clears only cached homes belonging to the selected source', () async {
    final rows = [
      HomeSection(
        title: 'Popular',
        items: [
          MediaItem(
            id: '1',
            title: 'Title',
            url: 'zm://anime/mal:1',
            type: ProviderType.anime,
            sourceId: 'zm',
          ),
        ],
      ),
    ];
    await HomeCache.write('zm', 'anime', rows);
    await HomeCache.write('other-source', 'all', rows);

    await HomeCache.clearSource('zm');

    expect(HomeCache.read('zm', 'anime'), isNull);
    expect(HomeCache.read('other-source', 'all'), isNotNull);
  });

  test(
    'preserves paging descriptor and lazy fallback across a cold read',
    () async {
      final rows = [
        HomeSection(
          title: 'Paged',
          items: [
            MediaItem(
              id: '1',
              title: 'Title',
              url: 'https://x.test/1',
              type: ProviderType.anime,
              sourceId: 'js:1',
            ),
          ],
          more: const BrowseMore(
            sourceId: 'js:1',
            kind: 'js_home',
            categoryId: 'row-a',
          ),
        ),
        HomeSection(
          title: 'Lazy only',
          items: [
            MediaItem(
              id: '2',
              title: 'Other',
              url: 'https://x.test/2',
              type: ProviderType.anime,
              sourceId: 'js:1',
            ),
          ],
          lazyFallback: true,
        ),
      ];
      await HomeCache.write('js:1', 'all', rows);

      final cached = HomeCache.read('js:1', 'all');
      expect(cached, isNotNull);
      expect(cached![0].more?.kind, 'js_home');
      expect(cached[0].more?.categoryId, 'row-a');
      expect(cached[1].lazyFallback, isTrue);
    },
  );
}
