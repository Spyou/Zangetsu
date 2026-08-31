import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/repository/source_domain_overrides.dart';

void main() {
  late Directory dir;
  late SourceDomainOverrides store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('domains');
    Hive.init(dir.path);
    store = await SourceDomainOverrides.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('normalize', () {
    test('adds the scheme a user will not type', () {
      expect(SourceDomainOverrides.normalize('netmirror.gg'),
          'https://netmirror.gg');
    });
    test('keeps an explicit scheme, including http', () {
      expect(SourceDomainOverrides.normalize('http://example.org'),
          'http://example.org');
    });
    test('drops trailing slashes so it concatenates like a reported base url',
        () {
      expect(SourceDomainOverrides.normalize('https://example.org///'),
          'https://example.org');
    });
    test('trims surrounding whitespace', () {
      expect(SourceDomainOverrides.normalize('  netmirror.gg  '),
          'https://netmirror.gg');
    });
    test('blank is not a domain', () {
      expect(SourceDomainOverrides.normalize('   '), isNull);
      expect(SourceDomainOverrides.normalize(''), isNull);
    });
    test('something with no host is not a domain', () {
      expect(SourceDomainOverrides.normalize('https://'), isNull);
    });
  });

  group('store', () {
    test('round-trips a set value', () async {
      expect(store.get('cs:Netflix'), isNull);
      await store.set('cs:Netflix', 'netmirror.gg');
      expect(store.get('cs:Netflix'), 'https://netmirror.gg');
    });

    test('saving a blank clears rather than storing an empty domain', () async {
      await store.set('cs:Netflix', 'netmirror.gg');
      await store.set('cs:Netflix', '   ');
      // Not '' — an empty override would hide the source's own domain and
      // leave the site actions pointing at nothing.
      expect(store.get('cs:Netflix'), isNull);
    });

    test('clear returns the source to its own domain', () async {
      await store.set('cs:Netflix', 'netmirror.gg');
      await store.clear('cs:Netflix');
      expect(store.get('cs:Netflix'), isNull);
    });

    test('one source override does not leak to another', () async {
      await store.set('cs:Netflix', 'netmirror.gg');
      expect(store.get('cs:4K HDHUB'), isNull);
    });
  });
}
