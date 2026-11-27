import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/companion/handoff_sources_wire.dart';

/// [n] proxied links that all carry the same [subtitles] (as a TV mirror
/// list does), each with its own quality and label.
List<VideoSource> _links(int n, List<Subtitle> subtitles) => [
  for (var i = 0; i < n; i++)
    VideoSource(
      url:
          'http://192.168.1.20:41234/p/tok3n/${base64Url.encode(utf8.encode('https://cdn$i.example.com/hls/episode-12/master.m3u8?token=abcdef$i'))}/master.m3u8',
      quality: i.isEven ? '1080p' : '720p',
      label: 'Server $i',
      container: SourceContainer.hls,
      kind: AudioKind.sub,
      audioLang: 'ja',
      subtitles: subtitles,
    ),
];

/// [n] proxied subtitle tracks with long upstream urls.
List<Subtitle> _subtitles(int n) => [
  for (var i = 0; i < n; i++)
    Subtitle(
      url:
          'http://192.168.1.20:41234/p/tok3n/${base64Url.encode(utf8.encode('https://subs.example.com/files/show/episode-12/track-$i.vtt?sig=0123456789abcdef'))}/subs.vtt',
      lang: 'lang$i',
      label: 'Language $i',
      format: 'vtt',
      isDefault: i == 0,
    ),
];

void main() {
  test('compact reply for 20 links sharing 30 subtitles is far smaller and '
      'reads back identically', () {
    final links = _links(20, _subtitles(30));
    final old = jsonEncode({
      'sources': [for (final s in links) s.toJson()],
    });
    final compact = jsonEncode(
      compactHandoffSources(links, total: links.length),
    );
    expect(compact.length, lessThan(old.length ~/ 5));
    final read = readHandoffSources(
      Map<String, dynamic>.from(jsonDecode(compact) as Map),
    );
    expect(read.sources, links);
    expect(read.more, isFalse);
  });

  test('links with their own subtitles and headers keep them', () {
    final subs = _subtitles(4);
    final links = [
      VideoSource(
        url: 'https://a.example.com/1.mp4',
        headers: const {'Referer': 'https://a.example.com/'},
        subtitles: subs,
      ),
      VideoSource(
        url: 'https://a.example.com/2.mp4',
        headers: const {'Referer': 'https://a.example.com/'},
        subtitles: [subs[2], subs[0]],
      ),
      const VideoSource(url: 'magnet:?xt=urn:btih:abc'),
      VideoSource(
        url: 'https://b.example.com/3.mp4',
        headers: const {'Referer': 'https://b.example.com/', 'Cookie': 'x=1'},
        subtitles: [subs[3]],
      ),
    ];
    final reply = compactHandoffSources(links, next: 5, total: 9);
    expect(reply['headers'], hasLength(2));
    expect(reply['subtitles'], hasLength(4));
    final read = readHandoffSources(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(reply)) as Map),
    );
    expect(read.sources, links);
    expect(read.nextOffset, 5);
    expect(read.total, 9);
  });

  test('an older TV reply in the full format is still read', () {
    final links = _links(3, _subtitles(2));
    final read = readHandoffSources(
      Map<String, dynamic>.from(
        jsonDecode(
              jsonEncode({
                'sources': [for (final s in links) s.toJson()],
              }),
            )
            as Map,
      ),
    );
    expect(read.sources, links);
    expect(read.more, isFalse);
  });
}
