import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/search_quality.dart';

void main() {
  group('qualityBadgeLabel', () {
    test('maps the CloudStream enum names to short badges', () {
      expect(qualityBadgeLabel('FourK'), '4K');
      expect(qualityBadgeLabel('UHD'), '4K');
      expect(qualityBadgeLabel('HD'), 'HD');
      expect(qualityBadgeLabel('Cam'), 'CAM');
      expect(qualityBadgeLabel('HdCam'), 'HD CAM');
      expect(qualityBadgeLabel('Telesync'), 'TS');
      expect(qualityBadgeLabel('BlueRay'), 'BLURAY');
      expect(qualityBadgeLabel('WebRip'), 'WEB');
    });

    test('nothing reported means no badge — the common case', () {
      expect(qualityBadgeLabel(null), isNull);
      expect(qualityBadgeLabel(''), isNull);
      expect(qualityBadgeLabel('   '), isNull);
    });

    test('an unknown value is shown rather than dropped', () {
      // A newer enum value, or a provider writing its own string: a label we
      // don't recognise still tells the viewer more than a blank poster.
      expect(qualityBadgeLabel('Remux'), 'REMUX');
    });
  });

}
