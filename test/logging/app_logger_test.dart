import 'dart:io';

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

  group('on-disk log', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('app-logger');
      file = File('${dir.path}/zangetsu.log');
      AppLogger.instance.clearForTest();
      await AppLogger.instance.initAt(file);
    });

    tearDown(() async {
      AppLogger.instance.clearForTest();
      await dir.delete(recursive: true);
    });

    test('a line is on disk straight away, not debounced', () async {
      // The log exists to explain a crash, and a crash takes the process with
      // it — a debounce would drop exactly the lines worth having.
      AppLogger.instance.log('something just broke');
      await AppLogger.instance.flush();
      expect(await file.readAsString(), contains('something just broke'));
    });

    test('every line lands, in order', () async {
      for (var i = 0; i < 10; i++) {
        AppLogger.instance.log('line $i');
      }
      await AppLogger.instance.flush();
      final lines = (await file.readAsLines())
          .where((l) => l.contains('line '))
          .toList();
      expect(lines.length, 10);
      expect(lines.first, contains('line 0'));
      expect(lines.last, contains('line 9'));
    });

    test('a burst of lines costs no whole-file rewrites', () async {
      // This is the fix. The old version joined the entire 2000-line buffer
      // and rewrote the whole file on EVERY line, so a source sweep meant
      // hundreds of both on the UI isolate.
      for (var i = 0; i < 200; i++) {
        AppLogger.instance.log('line $i');
      }
      await AppLogger.instance.flush();
      expect(AppLogger.instance.compactions, 0,
          reason: 'rewrote the whole file for a couple of hundred lines');
      expect(await file.readAsString(), contains('line 199'));
    });

    test('compaction still runs, so the file cannot grow forever', () async {
      for (var i = 0; i < 2500; i++) {
        AppLogger.instance.log('line $i');
      }
      await AppLogger.instance.flush();
      expect(AppLogger.instance.compactions, 1);
      final lines = await file.readAsLines();
      // Bounded by the buffer cap plus one compaction window, NOT by how many
      // lines were written.
      expect(lines.length, lessThanOrEqualTo(4001));
      expect(lines.last, contains('line 2499'));
    });

    test('redaction reaches the disk, not just the buffer', () async {
      AppLogger.instance.log('signed in as someone@example.com ok');
      await AppLogger.instance.flush();
      final onDisk = await file.readAsString();
      expect(onDisk, isNot(contains('someone@example.com')));
      expect(onDisk, contains('<email>'));
    });

    test('a restart picks up where the last run left off', () async {
      AppLogger.instance.log('before restart');
      await AppLogger.instance.flush();

      AppLogger.instance.clearForTest();
      await AppLogger.instance.initAt(file);
      expect(AppLogger.instance.contents, contains('before restart'));

      AppLogger.instance.log('after restart');
      await AppLogger.instance.flush();
      final onDisk = await file.readAsString();
      expect(onDisk, contains('before restart'));
      expect(onDisk, contains('after restart'));
    });
  });
}
