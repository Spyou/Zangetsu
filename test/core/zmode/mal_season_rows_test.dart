// MAL has no per-season ranking. "Trending" and "Popular this season" were
// BOTH `ranking_type=airing`, so the two rows showed the identical titles, and
// there was no recent-release row at all (that one is AniList's). Both are now
// cut from one request to the season endpoint.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/mal_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

String _ago(int days) => DateTime.now()
    .subtract(Duration(days: days))
    .toIso8601String()
    .split('T')
    .first;
String _ahead(int days) => DateTime.now()
    .add(Duration(days: days))
    .toIso8601String()
    .split('T')
    .first;

Map<String, dynamic> _node(int id, String title, String? start) => {
  'node': {
    'id': id,
    'title': title,
    if (start != null) 'start_date': start,
    'main_picture': {'large': 'https://x/$id.jpg'},
  },
};

void main() {
  late List<String> paths;

  MalCatalogue catalogue() {
    paths = [];
    final dio = Dio()
      ..httpClientAdapter = _Adapter((path) {
        paths.add(path);
        if (path.contains('/season/')) {
          return {
            'data': [
              // A long-runner that merely airs THROUGH this season.
              _node(21, 'One Piece', '1999-10-20'),
              _node(235, 'Conan', '1996-01-08'),
              // Actually began this season.
              _node(1, 'Older This Season', _ago(60)),
              _node(2, 'Newest This Season', _ago(3)),
              // Announced, not out.
              _node(3, 'Not Out Yet', _ahead(20)),
              // No date at all.
              _node(4, 'Undated', null),
            ],
          };
        }
        return {
          'data': [_node(99, 'From Ranking', _ago(400))],
        };
      });
    return MalCatalogue(dio);
  }

  test('Trending and Popular this season are no longer the same row', () async {
    final rows = await catalogue().home(ZKind.anime);
    final trending = rows.firstWhere((r) => r.title == 'Trending');
    final season = rows.firstWhere((r) => r.title == 'Popular this season');
    expect(
      trending.items.map((i) => i.title),
      isNot(equals(season.items.map((i) => i.title))),
      reason: 'this is the bug: two titles, one ranking_type=airing query',
    );
  });

  test('Popular this season drops shows that only air THROUGH it', () async {
    final rows = await catalogue().home(ZKind.anime);
    final titles = rows
        .firstWhere((r) => r.title == 'Popular this season')
        .items
        .map((i) => i.title)
        .toList();
    expect(titles, isNot(contains('One Piece')));
    expect(titles, isNot(contains('Conan')));
    expect(titles, contains('Newest This Season'));
  });

  test('Recently released is newest first, and only what is actually out',
      () async {
    final rows = await catalogue().home(ZKind.anime);
    final recent = rows.firstWhere((r) => r.title == 'Recently released');
    expect(recent.items.first.title, 'Newest This Season');
    expect(recent.items.map((i) => i.title), isNot(contains('Not Out Yet')));
    // No start date means we can't place it, so it isn't claimed as recent.
    expect(recent.items.map((i) => i.title), isNot(contains('Undated')));
    // One Piece is out, so it belongs — just last, being the oldest.
    expect(recent.items.last.title, 'Conan');
  });

  test('both seasonal rows come from ONE request', () async {
    await catalogue().home(ZKind.anime);
    expect(paths.where((p) => p.contains('/season/')).length, 1);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Map<String, dynamic> Function(String path) respond;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, __) async {
    return ResponseBody.fromString(
      const JsonEncoder().convert(respond(options.path)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
