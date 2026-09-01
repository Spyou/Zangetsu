// MAL has no novel endpoint: /manga/ranking answers for manga AND light
// novels, and only `media_type` says which came back. The old mapper stamped
// every item with the kind that was REQUESTED, so novel mode listed manga
// labelled as novels.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/mal_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

Map<String, dynamic> _node(int id, String title, String mediaType) => {
  'node': {
    'id': id,
    'title': title,
    'media_type': mediaType,
    'main_picture': {'large': 'https://x/$id.jpg'},
  },
};

void main() {
  late List<Map<String, dynamic>> lastQuery;

  MalCatalogue catalogue() {
    lastQuery = [];
    final dio = Dio()
      ..httpClientAdapter = _Adapter((q) {
        lastQuery.add(q);
        return {
          'data': [
            _node(1, 'A Manga', 'manga'),
            _node(2, 'A Light Novel', 'light_novel'),
            _node(3, 'A Novel', 'novel'),
            _node(4, 'A Manhwa', 'manhwa'),
          ],
        };
      });
    return MalCatalogue(dio);
  }

  test('novel mode returns only novels', () async {
    final rows = await catalogue().home(ZKind.novel);

    final titles = rows.expand((r) => r.items).map((i) => i.title).toSet();
    expect(titles, {'A Light Novel', 'A Novel'});
    expect(titles, isNot(contains('A Manga')),
        reason: 'this is the bug: manga showing up under Novel');
  });

  test('manga mode returns no novels', () async {
    final rows = await catalogue().home(ZKind.manga);

    final titles = rows.expand((r) => r.items).map((i) => i.title).toSet();
    expect(titles, contains('A Manga'));
    expect(titles, isNot(contains('A Light Novel')));
  });

  test('items carry their real type, not the requested one', () async {
    final rows = await catalogue().home(ZKind.novel);
    final types = rows.expand((r) => r.items).map((i) => i.type).toSet();

    expect(types, {ProviderType.novel});
  });

  test('a filtered kind asks for more than it needs', () async {
    await catalogue().home(ZKind.novel);

    // Roughly a third of a manga page is novels, so a page of 30 would leave
    // a row with about eight entries.
    expect(lastQuery.first['limit'], greaterThan(30));
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Map<String, dynamic> Function(Map<String, dynamic>) respond;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, __) async {
    final body = respond(Map<String, dynamic>.from(options.queryParameters));
    return ResponseBody.fromString(
      _encode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _encode(Object o) => const JsonEncoder().convert(o);
