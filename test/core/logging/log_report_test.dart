import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/logging/log_report_service.dart';

void main() {
  group('refOf', () {
    test('takes the reference out of the Worker reply', () {
      expect(LogReportService.refOf({'ref': 'K7M2QX'}), 'K7M2QX');
      expect(LogReportService.refOf('{"ref":"K7M2QX"}'), 'K7M2QX');
      expect(LogReportService.refOf({'ref': '  K7M2QX  '}), 'K7M2QX');
    });

    test('anything that is not a reference reads as "did not send"', () {
      // A captive portal or proxy answers 200 with an HTML login page. Telling
      // the user it sent, and handing them a code that matches no report, is
      // worse than saying it failed.
      expect(LogReportService.refOf('<html>Sign in to WiFi</html>'), isNull);
      expect(LogReportService.refOf({'error': 'too large'}), isNull);
      expect(LogReportService.refOf({'ref': ''}), isNull);
      expect(LogReportService.refOf({'ref': 'not a ref!'}), isNull);
      expect(LogReportService.refOf({'ref': 42}), isNull);
      expect(LogReportService.refOf(null), isNull);
    });
  });

  test('deviceLabel is short, ASCII and never throws', () {
    final label = LogReportService.deviceLabel();
    expect(label, isNotEmpty);
    // Goes out as an HTTP header, which is ASCII-only.
    expect(RegExp(r'^[\x20-\x7E]*$').hasMatch(label), isTrue);
  });
}
