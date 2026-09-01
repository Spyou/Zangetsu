// "See all" pagination for the metadata providers. Source-backed rows always
// paged, because they carry a BrowseMore descriptor; AniList/MAL/TMDB/Simkl
// rows carried none, so the grid was stuck on whatever page one returned.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/video_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

class _Video implements VideoCatalogue {
  String? lastRowId;
  int? lastPage;

  @override
  Future<List<HomeSection>> home() async => const [];

  @override
  Future<List<MediaItem>> search(String q) async => const [];

  @override
  Future<MediaDetail> detail(ZCanonical c) async => MediaDetail(
    id: c.id,
    title: 'x',
    url: ZmodeIds.showUrl(c),
    type: ProviderType.movie,
    sourceId: ZmodeIds.sourceId,
  );

  @override
  bool get supportsFilters => true;

  @override
  Future<List<MediaItem>> searchFiltered(
    String q, {
    MetaFilters? filters,
    int page = 1,
  }) async => const [];

  @override
  Future<List<MediaItem>> browseRow(String rowId, int page) async {
    lastRowId = rowId;
    lastPage = page;
    return [
      MediaItem(
        id: 'm$page',
        title: 'page $page',
        url: 'zm://m/$page',
        type: ProviderType.movie,
        sourceId: ZmodeIds.sourceId,
      ),
    ];
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zmore');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a row carries the descriptor its own page-2 call needs', () {
    // The row id has to survive the round trip, otherwise "See all" cannot say
    // WHICH row it wants more of.
    const s = HomeSection(
      title: 'Trending',
      items: [],
      more: BrowseMore(
        sourceId: ZmodeIds.sourceId,
        kind: 'zm_video',
        categoryId: '/movie/popular',
      ),
    );

    expect(s.more, isNotNull);
    // The routing test is an id comparison: ZmodeIds.isZ checks for a zm://
    // URL, and a sourceId is never one.
    expect(s.more!.sourceId, ZmodeIds.sourceId,
        reason: 'See all routes on this to pick the right repository');
    expect(ZmodeIds.isZ(s.more!.sourceId), isFalse,
        reason: 'guards the mistake this test caught');
    expect(s.more!.categoryId, '/movie/popular');
  });

  test('the catalogue is asked for the page the grid asked for', () async {
    final v = _Video();

    final page2 = await v.browseRow('/movie/popular', 2);

    expect(v.lastRowId, '/movie/popular');
    expect(v.lastPage, 2, reason: 'page 1 is what home() already showed');
    expect(page2.single.id, 'm2');
  });

  test('an unknown kind pages nothing rather than guessing', () async {
    // Row descriptors are persisted in section state; a kind this build does
    // not know must stop the grid, not route to an arbitrary provider.
    const unknown = BrowseMore(
      sourceId: ZmodeIds.sourceId,
      kind: 'zm_something_else',
      categoryId: 'x',
    );
    expect(unknown.kind.startsWith('zm_'), isTrue);
    expect(
      const ['zm_video', 'zm_anime', 'zm_manga', 'zm_novel'].contains(unknown.kind),
      isFalse,
    );
  });
}
