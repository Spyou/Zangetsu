// test/core/cast/cast_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/cast/cast_controller.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  test('castSubtitleMaps sends format=vtt and drops ASS', () {
    const vtt = Subtitle(
      url: 'https://cdn.example/en.vtt',
      lang: 'en',
      label: 'English',
      format: 'vtt',
    );
    const srt = Subtitle(
      url: 'https://cdn.example/es.srt',
      lang: 'es',
      format: 'srt',
    );
    const ass = Subtitle(
      url: 'https://cdn.example/ja.ass',
      lang: 'ja',
      format: 'ass',
    );
    expect(canCastSubtitle(vtt), isTrue);
    expect(canCastSubtitle(srt), isTrue);
    expect(canCastSubtitle(ass), isFalse);
    final maps = castSubtitleMaps([vtt, srt, ass]);
    expect(maps, hasLength(2));
    expect(maps[0]['format'], 'vtt');
    expect(maps[1]['format'], 'vtt');
    expect(maps[1]['url'], srt.url);
  });

  test('castPlayerStateName / castIdleReasonName label CAF ints', () {
    expect(castPlayerStateName(2), 'playing');
    expect(castPlayerStateName(4), 'buffering');
    expect(castPlayerStateName(99), 'unknown(99)');
    expect(castIdleReasonName(0), 'none');
    expect(castIdleReasonName(2), 'canceled');
  });

  test('castMimeFor maps containers + sniffs unknown by extension', () {
    expect(castMimeFor(SourceContainer.hls, 'x'), 'application/x-mpegURL');
    expect(castMimeFor(SourceContainer.mp4, 'x'), 'video/mp4');
    expect(
      castMimeFor(SourceContainer.unknown, 'http://a/b.m3u8?t=1'),
      'application/x-mpegURL',
    );
    expect(castMimeFor(SourceContainer.unknown, 'http://a/b.mp4'), 'video/mp4');
  });
}
