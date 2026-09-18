import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/cast/cast_proxy.dart';

void main() {
  test(
    'phone handoff proxies local HLS, headers, redirects and seeking while rejecting unknown targets',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = CastProxyServer(restrictTargets: true);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.stop();
        await upstream.close(force: true);
      });
      upstream.listen((req) async {
        final res = req.response;
        if (req.headers.value('X-Session') != 'tv-session') {
          res.statusCode = 403;
        } else if (req.uri.path == '/start') {
          res.statusCode = 302;
          res.headers.set('Location', '/episode/index.m3u8');
        } else if (req.uri.path == '/episode/index.m3u8') {
          res.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          res.write('#EXTM3U\n#EXTINF:4,\nsegment.ts\n');
        } else if (req.uri.path == '/episode/segment.ts') {
          if (req.headers.value('Range') == 'bytes=2-4') {
            res.statusCode = 206;
            res.headers.set('Content-Range', 'bytes 2-4/6');
            res.write('cde');
          } else {
            res.write('abcdef');
          }
        } else {
          res.statusCode = 404;
        }
        await res.close();
      });
      final address = await proxy.serve(
        'http://127.0.0.1:${upstream.port}/start',
        {'X-Session': 'tv-session'},
      );
      expect(address, isNotNull);
      final uri = Uri.parse(address!).replace(host: '127.0.0.1');
      final playlist = await (await client.getUrl(uri)).close();
      expect(playlist.statusCode, 200);
      final body = await playlist.transform(utf8.decoder).join();
      final segment = body
          .split('\n')
          .firstWhere((line) => line.startsWith('/p/'));
      final request = await client.getUrl(uri.resolve(segment));
      request.headers.set('Range', 'bytes=2-4');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('Content-Range'), 'bytes 2-4/6');
      expect(await response.transform(utf8.decoder).join(), 'cde');
      final unknown = uri.replace(
        queryParameters: {
          'u': base64Url.encode(
            utf8.encode('http://127.0.0.1:${upstream.port}/private'),
          ),
        },
      );
      final rejected = await (await client.getUrl(unknown)).close();
      expect(rejected.statusCode, 403);
      await rejected.drain<void>();
    },
  );
}
