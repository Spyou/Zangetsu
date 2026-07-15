// test/core/cast/cast_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/cast/cast_controller.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  test('castMimeFor maps containers + sniffs unknown by extension', () {
    expect(castMimeFor(SourceContainer.hls, 'x'), 'application/x-mpegURL');
    expect(castMimeFor(SourceContainer.mp4, 'x'), 'video/mp4');
    expect(castMimeFor(SourceContainer.unknown, 'http://a/b.m3u8?t=1'),
        'application/x-mpegURL');
    expect(castMimeFor(SourceContainer.unknown, 'http://a/b.mp4'), 'video/mp4');
  });
}
