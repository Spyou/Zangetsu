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

  test('deviceLabel never throws, even with no platform channels', () async {
    // DeviceInfoPlugin needs a real platform; in a test it throws and the
    // plain Platform values have to carry it.
    final label = await LogReportService.deviceLabel();
    expect(label, isNotEmpty);
  });

  test('ascii strips what an HTTP header cannot carry', () {
    // A device model or a mode label can contain anything; headers are ASCII,
    // and a non-Latin character would throw on the way out.
    expect(LogReportService.ascii('Xiaomi 2209116AG'), 'Xiaomi 2209116AG');
    expect(LogReportService.ascii('  padded  '), 'padded');
    expect(LogReportService.ascii('Xiaomi·Redmi'), 'XiaomiRedmi');
    expect(
      RegExp(r'^[\x20-\x7E]*$').hasMatch(LogReportService.ascii('日本語 v2')),
      isTrue,
    );
  });

  group('sourcesSummary', () {
    test('counts by ecosystem so we stop having to ask', () {
      expect(
        LogReportService.sourcesSummary([
          'cs:Netflix', 'cs:Hotstar',
          'ani:1234',
          'mihon:99', 'mihon:100', 'mihon:101',
          'lnr:novelupdates',
          'allanime', 'hianime',
        ]),
        'js:2 cs:2 ani:1 mihon:3 lnr:1',
      );
    });

    test('an unprefixed id counts as a JS provider', () {
      // JS sources have bare ids — everything else carries its prefix.
      expect(LogReportService.sourcesSummary(['allanime']), 'js:1 cs:0 ani:0 mihon:0 lnr:0');
    });

    test('no sources installed still reports', () {
      expect(LogReportService.sourcesSummary([]), 'js:0 cs:0 ani:0 mihon:0 lnr:0');
    });
  });
}
