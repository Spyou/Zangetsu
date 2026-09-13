import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';

/// Fails the first [failures] requests for any URL containing [failFor], then
/// answers normally. Counts every attempt so a test can prove a retry happened
/// rather than inferring it from the result.
class _FlakyAdapter implements HttpClientAdapter {
  _FlakyAdapter({
    required this.failFor,
    required this.failures,
    this.status = 500,
  });

  final String failFor;
  final int failures;
  final int status;

  /// Any non-empty body will do — nothing here inspects segment contents.
  static const _body = 'segment-bytes';

  final attempts = <String>[];
  int _failed = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, _) async {
    attempts.add(o.uri.toString());
    if (o.uri.toString().contains(failFor) && _failed < failures) {
      _failed++;
      if (status == 0) throw DioException(requestOptions: o, message: 'reset');
      return ResponseBody.fromString('', status);
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(_body.codeUnits),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 2)));
  dio.httpClientAdapter = adapter;
  return dio;
}

/// A one-variant media playlist with [n] segments, served for any .m3u8 URL.
String _playlist(int n) => [
  '#EXTM3U',
  '#EXT-X-TARGETDURATION:4',
  '#EXT-X-MEDIA-SEQUENCE:0',
  for (var i = 0; i < n; i++) ...['#EXTINF:4.0,', 'https://cdn.test/seg$i.ts'],
  '#EXT-X-ENDLIST',
].join('\n');

/// Serves the playlist, and delegates segment requests to [inner] so the flaky
/// behaviour only applies to segments.
class _PlaylistAdapter implements HttpClientAdapter {
  _PlaylistAdapter(this.inner, this.segments);
  final _FlakyAdapter inner;
  final int segments;

  @override
  Future<ResponseBody> fetch(RequestOptions o, a, b) async {
    if (o.uri.toString().endsWith('.m3u8')) {
      return ResponseBody.fromString(_playlist(segments), 200);
    }
    return inner.fetch(o, a, b);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl-retry');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('HLS segment retry', () {
    test('a segment that fails twice still completes the download', () async {
      // The reported shape: one flaky segment used to end the whole download
      // AND delete the partial file, so segment 900 of 1000 failing threw away
      // all 900.
      final flaky = _FlakyAdapter(failFor: 'seg1.ts', failures: 2);
      final out = '${dir.path}/out.mp4';

      final err = await HlsDownloader(
        _dioWith(_PlaylistAdapter(flaky, 3)),
      ).download(
        url: 'https://cdn.test/index.m3u8',
        outputPath: out,
        headers: const {},
        preferredQuality: 'best',
        onProgress: (_) {},
        canceled: () => false,
      );

      expect(err, isNull, reason: 'should have recovered, not failed');
      expect(File(out).existsSync(), isTrue);
      final tries = flaky.attempts.where((u) => u.contains('seg1.ts')).length;
      expect(tries, 3, reason: 'two failures then a success');
    });

    test('a segment that never recovers gives up rather than looping', () async {
      // Retrying forever would leave a download sitting at 90% indefinitely.
      final flaky = _FlakyAdapter(failFor: 'seg1.ts', failures: 999);
      final out = '${dir.path}/out.mp4';

      final err = await HlsDownloader(
        _dioWith(_PlaylistAdapter(flaky, 3)),
      ).download(
        url: 'https://cdn.test/index.m3u8',
        outputPath: out,
        headers: const {},
        preferredQuality: 'best',
        onProgress: (_) {},
        canceled: () => false,
      );

      expect(err, isNotNull);
      final tries = flaky.attempts.where((u) => u.contains('seg1.ts')).length;
      expect(tries, 3, reason: 'the attempt budget, not an endless loop');
    });

    test('a 404 segment is not retried', () async {
      // The CDN answered and the answer is no. Asking twice more only makes
      // the failure slower.
      final flaky = _FlakyAdapter(
        failFor: 'seg1.ts',
        failures: 999,
        status: 404,
      );
      final out = '${dir.path}/out.mp4';

      await HlsDownloader(_dioWith(_PlaylistAdapter(flaky, 3))).download(
        url: 'https://cdn.test/index.m3u8',
        outputPath: out,
        headers: const {},
        preferredQuality: 'best',
        onProgress: (_) {},
        canceled: () => false,
      );

      final tries = flaky.attempts.where((u) => u.contains('seg1.ts')).length;
      expect(tries, 1, reason: 'a 4xx is final');
    });

    test('a dropped connection is retried, not just a bad status', () async {
      // Timeouts and resets are what a retry is actually for, and they arrive
      // as a thrown DioException rather than a status code.
      final flaky = _FlakyAdapter(failFor: 'seg1.ts', failures: 1, status: 0);
      final out = '${dir.path}/out.mp4';

      final err = await HlsDownloader(
        _dioWith(_PlaylistAdapter(flaky, 3)),
      ).download(
        url: 'https://cdn.test/index.m3u8',
        outputPath: out,
        headers: const {},
        preferredQuality: 'best',
        onProgress: (_) {},
        canceled: () => false,
      );

      expect(err, isNull);
      expect(File(out).existsSync(), isTrue);
    });
  });
}
