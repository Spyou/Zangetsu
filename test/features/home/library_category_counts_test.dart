import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/category_store.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';
import 'package:watch_app/features/home/library_filter.dart';

class _CountingCategories extends CategoryStore {
  _CountingCategories(String Function() profile)
    : super(currentProfileId: profile);
  int reads = 0;
  @override
  Set<String> categoriesOf(MediaItem item) {
    reads++;
    return super.categoriesOf(item);
  }
}

const anime = MediaItem(
  id: 'a',
  title: 'Anime',
  url: '/a',
  sourceId: 's',
  type: ProviderType.anime,
);
const manga = MediaItem(
  id: 'm',
  title: 'Manga',
  url: '/m',
  sourceId: 's',
  type: ProviderType.manga,
);

void main() {
  late Directory dir;
  late _CountingCategories store;
  late LibraryCategoryCounts cache;
  var profile = 'first';
  final entries = [
    const MyListEntry(anime, null),
    const MyListEntry(manga, null),
  ];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('library_counts');
    Hive.init(dir.path);
    await Hive.openBox(CategoryStore.boxName);
    profile = 'first';
    store = _CountingCategories(() => profile);
    cache = LibraryCategoryCounts(store);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'reuses counts on resize, and counts each title only once per kind',
    () async {
      final a = (await store.create('A'))!;
      final b = (await store.create('B'))!;
      await store.setMembership(anime, a.id, true);
      await store.setMembership(anime, b.id, true);
      final counts = cache.forEntries(entries, ContentMode.anime);
      expect(counts, {a.id: 1, b.id: 1});
      expect(store.reads, 1);
      expect(cache.forEntries(entries, ContentMode.anime), same(counts));
      expect(store.reads, 1);
    },
  );

  test('adding and removing membership invalidates counts', () async {
    final cat = (await store.create('A'))!;
    expect(cache.forEntries(entries, ContentMode.anime), isEmpty);
    await store.setMembership(anime, cat.id, true);
    expect(cache.forEntries(entries, ContentMode.anime), {cat.id: 1});
    await store.setMembership(anime, cat.id, false);
    expect(cache.forEntries(entries, ContentMode.anime), isEmpty);
  });

  test('added and removed list entries invalidate counts', () async {
    final cat = (await store.create('A'))!;
    await store.setMembership(anime, cat.id, true);
    expect(cache.forEntries(const [], ContentMode.anime), isEmpty);
    expect(cache.forEntries(entries, ContentMode.anime), {cat.id: 1});
    expect(cache.forEntries(const [], ContentMode.anime), isEmpty);
  });

  test('content modes have separate cached counts', () async {
    final cat = (await store.create('A'))!;
    await store.setMembership(anime, cat.id, true);
    await store.setMembership(manga, cat.id, true);
    expect(cache.forEntries(entries, ContentMode.anime), {cat.id: 1});
    expect(cache.forEntries(entries, ContentMode.manga), {cat.id: 1});
    expect(cache.forEntries(entries, ContentMode.novel), isEmpty);
    expect(store.reads, 2);
    cache.forEntries(entries, ContentMode.anime);
    expect(store.reads, 2);
  });

  test('changing profiles never reuses the other profile counts', () async {
    final cat = (await store.create('A'))!;
    await store.setMembership(anime, cat.id, true);
    expect(cache.forEntries(entries, ContentMode.anime), {cat.id: 1});
    profile = 'second';
    expect(cache.forEntries(entries, ContentMode.anime), isEmpty);
    profile = 'first';
    expect(cache.forEntries(entries, ContentMode.anime), {cat.id: 1});
  });

  test(
    'global category counts preserve assignments outside the visible list',
    () async {
      final cat = (await store.create('Legacy'))!;
      expect(cache.total(cat.id), 0);
      await store.setMembership(manga, cat.id, true);
      expect(cache.forEntries(const [], ContentMode.anime), isEmpty);
      expect(cache.total(cat.id), 1);
      profile = 'second';
      expect(cache.total(cat.id), 0);
    },
  );

  test('deleting a category removes its cached membership counts', () async {
    final cat = (await store.create('A'))!;
    await store.setMembership(anime, cat.id, true);
    expect(cache.forEntries(entries, ContentMode.anime), {cat.id: 1});
    await store.delete(cat.id);
    expect(cache.forEntries(entries, ContentMode.anime), isEmpty);
    expect(cache.total(cat.id), 0);
  });
}
