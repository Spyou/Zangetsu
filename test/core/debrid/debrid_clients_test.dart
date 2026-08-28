import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/debrid/debrid_result.dart';
import 'package:watch_app/core/debrid/real_debrid_client.dart';
import 'package:watch_app/core/debrid/torbox_client.dart';

class _SeqAdapter implements HttpClientAdapter {
  _SeqAdapter(this.handlers);
  final List<ResponseBody Function(RequestOptions)> handlers;
  int i = 0;
  final seen = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    if (i >= handlers.length) {
      return ResponseBody.fromString(
        'unexpected ${options.method} ${options.uri}',
        500,
      );
    }
    return handlers[i++](options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  const magnet =
      'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';
  const token = 'test-token';

  group('RealDebridClient', () {
    test('validateToken is true on 200 /user', () async {
      final adapter = _SeqAdapter([(_) => _json({'id': 1, 'username': 'x'})]);
      final dio = Dio(BaseOptions(baseUrl: RealDebridClient.kBase))
        ..httpClientAdapter = adapter;
      expect(await RealDebridClient(dio: dio).validateToken(token), isTrue);
    });

    test('validateToken is false on 401', () async {
      final adapter = _SeqAdapter([(_) => _json({'error': 'bad'}, 401)]);
      final dio = Dio(BaseOptions(baseUrl: RealDebridClient.kBase))
        ..httpClientAdapter = adapter;
      expect(await RealDebridClient(dio: dio).validateToken(token), isFalse);
    });

    test('resolve happy path: addMagnet → select → unrestrict', () async {
      final adapter = _SeqAdapter([
        (o) {
          expect(o.path, '/torrents/addMagnet');
          return _json({'id': 'tid'});
        },
        (o) {
          expect(o.path, '/torrents/info/tid');
          return _json({
            'status': 'waiting_files_selection',
            'files': [
              {'id': 1, 'path': '/sample.mkv', 'bytes': 10},
              {'id': 2, 'path': '/episode.mkv', 'bytes': 999},
            ],
          });
        },
        (o) {
          expect(o.path, '/torrents/selectFiles/tid');
          return _json({});
        },
        (o) {
          expect(o.path, '/torrents/info/tid');
          return _json({
            'status': 'downloaded',
            'links': ['https://hoster.example/f'],
          });
        },
        (o) {
          expect(o.path, '/unrestrict/link');
          return _json({
            'download': 'https://cdn.example/episode.mkv',
            'filename': 'episode.mkv',
            'filesize': 999,
          });
        },
      ]);
      final dio = Dio(BaseOptions(baseUrl: RealDebridClient.kBase))
        ..httpClientAdapter = adapter;
      final out = await RealDebridClient(dio: dio).resolve(
        magnet,
        token: token,
        timeout: const Duration(seconds: 10),
      );
      expect(out.url, 'https://cdn.example/episode.mkv');
      expect(out.filename, 'episode.mkv');
    });

    test('Prefer (requireCached) fails when RD starts downloading', () async {
      final adapter = _SeqAdapter([
        (_) => _json({'id': 'tid'}),
        (_) => _json({
              'status': 'waiting_files_selection',
              'files': [
                {'id': 1, 'path': '/ep.mkv', 'bytes': 10},
              ],
            }),
        (_) => _json({}), // selectFiles
        (_) => _json({'status': 'downloading'}),
        (_) => _json({}), // delete
      ]);
      final dio = Dio(BaseOptions(baseUrl: RealDebridClient.kBase))
        ..httpClientAdapter = adapter;
      try {
        await RealDebridClient(dio: dio).resolve(
          magnet,
          token: token,
          timeout: const Duration(seconds: 10),
          requireCached: true,
        );
        fail('expected notCached');
      } on DebridException catch (e) {
        expect(e.kind, DebridFailure.notCached);
      }
    });
  });

  group('TorBoxClient', () {
    test('validateToken is true on success', () async {
      final adapter = _SeqAdapter([
        (_) => _json({
              'success': true,
              'data': {'id': 1, 'email': 'a@b.c'},
            }),
      ]);
      final dio = Dio(BaseOptions(baseUrl: TorBoxClient.kBase))
        ..httpClientAdapter = adapter;
      expect(await TorBoxClient(dio: dio).validateToken(token), isTrue);
    });

    test('Prefer skips create when checkcached misses', () async {
      final adapter = _SeqAdapter([
        (o) {
          expect(o.path, '/torrents/checkcached');
          return _json({'success': true, 'data': {}});
        },
      ]);
      final dio = Dio(BaseOptions(baseUrl: TorBoxClient.kBase))
        ..httpClientAdapter = adapter;
      try {
        await TorBoxClient(dio: dio).resolve(
          magnet,
          token: token,
          timeout: const Duration(seconds: 10),
          requireCached: true,
        );
        fail('expected notCached');
      } on DebridException catch (e) {
        expect(e.kind, DebridFailure.notCached);
      }
    });

    test('resolve happy path: cached → create → permalink', () async {
      final adapter = _SeqAdapter([
        (_) => _json({
              'success': true,
              'data': {
                '0123456789abcdef0123456789abcdef01234567': {'name': 'ep'},
              },
            }),
        (o) {
          expect(o.path, '/torrents/createtorrent');
          return _json({
            'success': true,
            'data': {'torrent_id': 42},
          });
        },
        (o) {
          expect(o.path, '/torrents/mylist');
          return _json({
            'success': true,
            'data': {
              'id': 42,
              'download_finished': true,
              'files': [
                {'id': 7, 'name': 'episode.mkv', 'size': 1234},
              ],
            },
          });
        },
      ]);
      final dio = Dio(BaseOptions(baseUrl: TorBoxClient.kBase))
        ..httpClientAdapter = adapter;
      final out = await TorBoxClient(dio: dio).resolve(
        magnet,
        token: token,
        timeout: const Duration(seconds: 10),
        requireCached: true,
      );
      expect(out.url, contains('torrent_id=42'));
      expect(out.url, contains('file_id=7'));
      expect(out.url, contains('redirect=true'));
      expect(out.filename, 'episode.mkv');
    });
  });
}
