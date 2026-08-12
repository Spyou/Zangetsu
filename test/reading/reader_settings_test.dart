import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/reader_settings.dart';

void main() {
  group('readerDecodeWidth', () {
    test('scales device width by zoom headroom', () {
      expect(readerDecodeWidth(1080), 2160); // 2x headroom for pinch-zoom
    });
    test('never returns below device width', () {
      expect(readerDecodeWidth(1080, zoomHeadroom: 0.5), 1080);
    });
    test('caps to a sane maximum so huge webtoon strips do not decode 8k wide', () {
      expect(readerDecodeWidth(4000), 4096);
    });
  });
}
