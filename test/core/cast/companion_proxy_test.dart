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
          .firstWhere((line) => line.startsWith('http://'));
      // Upstream casting now emits absolute, path-encoded URLs. The companion
      // must retain target registration and range forwarding with that format.
      final request = await client.getUrl(
        Uri.parse(segment).replace(host: '127.0.0.1'),
      );
      request.headers.set('Range', 'bytes=2-4');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('Content-Range'), 'bytes 2-4/6');
      expect(await response.transform(utf8.decoder).join(), 'cde');
      final unknown = uri.replace(
        pathSegments: [
          ...uri.pathSegments.take(2),
          base64Url.encode(
            utf8.encode('http://127.0.0.1:${upstream.port}/private'),
          ),
          'seg',
        ],
      );
      final rejected = await (await client.getUrl(unknown)).close();
      expect(rejected.statusCode, 403);
      await rejected.drain<void>();
    },
  );

  test('companion proxy accepts targets that Uri.parse would normalise', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = CastProxyServer(restrictTargets: true);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await upstream.close(force: true);
    });
    upstream.listen((req) async {
      req.response.write('media');
      await req.response.close();
    });
    final address = await proxy.serve(
      'http://127.0.0.1:${upstream.port}/a.mp4?sig=a+b%3d&t=[1]',
      const {},
    );
    final uri = Uri.parse(address!).replace(host: '127.0.0.1');
    final res = await (await client.getUrl(uri)).close();
    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), 'media');
  });

  test('cast proxy keeps .m3u8 playlists that redirect to a plain path', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = CastProxyServer();
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await upstream.close(force: true);
    });
    upstream.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/x.m3u8') {
        res.statusCode = 302;
        res.headers.set('Location', '/hls/abc?token=1');
      } else {
        res.headers.contentType = ContentType.text;
        res.write('#EXTM3U\n#EXTINF:4,\nseg.ts\n');
      }
      await res.close();
    });
    final address = await proxy.serve(
      'http://127.0.0.1:${upstream.port}/x.m3u8',
      const {},
    );
    final uri = Uri.parse(address!).replace(host: '127.0.0.1');
    final res = await (await client.getUrl(uri)).close();
    final body = await res.transform(utf8.decoder).join();
    expect(
      body.split('\n').where((l) => l.contains('/p/')),
      isNotEmpty,
      reason: body,
    );
  });
}
