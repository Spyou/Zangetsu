import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/logging/app_logger.dart';

void main() {
  test('ring buffer keeps only the most recent lines', () {
    final log = AppLogger.instance..clearForTest();
    for (var i = 0; i < 2100; i++) {
      log.log('line $i');
    }
    final lines = log.contents.split('\n');
    expect(lines.length, lessThanOrEqualTo(2000));
    expect(log.contents.contains('line 2099'), true); // newest kept
    expect(log.contents.contains('line 0 '), false); // oldest dropped
  });

  test('redact strips emails, keys, jwts and token values', () {
    expect(AppLogger.redact('user chatgptkrylor@gmail.com in'),
        isNot(contains('@gmail.com')));
    expect(
        AppLogger.redact('key standard_2c3735bd0e4461c4813c4359d0617ba5'),
        isNot(contains('standard_2c37')));
    expect(
        AppLogger.redact('jwt eyAbc123._payLoad-9.sig_ABC then'),
        isNot(contains('eyAbc123')));
    expect(AppLogger.redact('Authorization: Bearer_xyz123'),
        contains('<redacted>'));
  });

  test('logError records the error and a trimmed stack', () {
    final log = AppLogger.instance..clearForTest();
    log.logError('boom', StackTrace.fromString('a\nb\nc'));
    expect(log.contents, contains('boom'));
    expect(log.contents, contains('E'));
  });
}
