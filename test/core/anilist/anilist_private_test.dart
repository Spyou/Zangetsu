import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_store.dart';
import 'package:watch_app/core/anilist/anilist_api.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool failSave = false;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'data': failSave
            ? null
            : {
                'SaveMediaListEntry': {'id': 1},
                'Media': {
                  'title': {'romaji': 'Private title'},
                  'mediaListEntry': {'private': true, 'status': 'CURRENT'},
                },
              },
      }),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('authenticated service', () {
    late Directory dir;
    late AniListService service;
    late _Adapter adapter;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('anilist_private');
      Hive.init(dir.path);
      await AniListStore.init();
      final store = AniListStore();
      await store.saveSession(token: 'test-token', expiresAt: 0);
      await store.saveViewer(id: 1, name: 'owner');
      adapter = _Adapter();
      service = AniListService(Dio()..httpClientAdapter = adapter);
    });
    tearDown(() async {
      service.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    test(
      'fetch reads privacy and a privacy-only write preserves other fields',
      () async {
        final entry = await service.fetchEntry(pinnedId: '7');
        expect(entry?.isPrivate, isTrue);
        await service.updateEntry(pinnedId: '7', isPrivate: false);
        expect(adapter.requests.last.data['variables'], {
          'mediaId': 7,
          'private': false,
        });
      },
    );
    test('failed or disconnected privacy writes report failure', () async {
      adapter.failSave = true;
      await expectLater(
        service.updateEntry(pinnedId: '7', isPrivate: true),
        throwsStateError,
      );
      await service.store.clearSession();
      final count = adapter.requests.length;
      await expectLater(
        service.updateEntry(pinnedId: '7', isPrivate: true),
        throwsStateError,
      );
      expect(adapter.requests, hasLength(count));
    });
  });
  test('entry and collection queries request privacy for both media kinds', () {
    for (final kind in [MediaKind.anime, MediaKind.manga]) {
      expect(mediaEntryQuery(kind), contains('private'));
      expect(mediaListCollectionQuery(kind), contains('private'));
    }
  });

  test('collection keeps private entries and their privacy flag', () {
    final items = parseAniListCollection({
      'data': {
        'MediaListCollection': {
          'lists': [
            {
              'entries': [
                {
                  'status': 'CURRENT',
                  'private': true,
                  'media': {
                    'id': 7,
                    'idMal': 8,
                    'title': {'romaji': 'Private title'},
                  },
                },
                {
                  'status': 'PLANNING',
                  'media': {
                    'id': 9,
                    'idMal': 10,
                    'title': {'romaji': 'Public title'},
                  },
                },
              ],
            },
          ],
        },
      },
    }, MediaKind.anime);
    expect(items, hasLength(2));
    expect(items.first.isPrivate, isTrue);
    expect(items.last.isPrivate, isFalse);
  });

  test('privacy can be enabled or disabled; ordinary edits omit it', () async {
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final api = AniListApi(dio, () => 'test-token');
    for (final value in [true, false]) {
      expect(await api.saveEntry(mediaId: 7, isPrivate: value), isTrue);
      final request = adapter.requests.last;
      expect(request.headers['Authorization'], 'Bearer test-token');
      expect(request.data['query'], contains('private:\$private'));
      expect(request.data['variables']['private'], value);
      expect(
        request.data['variables'].keys,
        unorderedEquals(['mediaId', 'private']),
      );
    }
    await api.saveEntry(mediaId: 7, progress: 3);
    expect(adapter.requests.last.data['variables'], {
      'mediaId': 7,
      'progress': 3,
    });
    expect(adapter.requests.last.data['query'], isNot(contains('private')));
    dio.close();
  });
}
