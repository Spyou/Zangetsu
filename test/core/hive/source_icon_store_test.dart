import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/hive/source_icon_store.dart';
import 'package:watch_app/core/mihon/mihon_repo.dart';

/// Icons for Aniyomi/Mihon rows in the source picker. The source objects
/// those ecosystems hand back carry no icon — only the repo index names one —
/// so the entry derives the URL and [SourceIconStore] keeps it for the picker.

AniyomiRepoEntry _entry({
  required String pkg,
  required String base,
  String absoluteIconUrl = '',
}) => AniyomiRepoEntry(
  name: 'Some Source',
  pkg: pkg,
  apk: 'ext-v1.0.apk',
  lang: 'en',
  version: '1.0',
  code: 1,
  nsfw: false,
  sources: const [],
  repoBaseUrl: base,
  absoluteIconUrl: absoluteIconUrl,
);

void main() {
  group('AniyomiRepoEntry.iconUrl', () {
    test('is derived from the repo base and the package name', () {
      final e = _entry(
        pkg: 'com.test.ext.one',
        base: 'https://raw.test/owner/repo/main',
      );
      expect(e.iconUrl, 'https://raw.test/owner/repo/main/icon/com.test.ext.one.png');
    });

    test('normalises a base that still points at the index file', () {
      // Users paste the link to index.min.json itself; left as-is that builds
      // `.../index.min.json/icon/....png`, which 404s on every repo.
      final e = _entry(
        pkg: 'com.test.ext.one',
        base: 'https://raw.test/owner/repo/main/index.min.json',
      );
      expect(e.iconUrl, 'https://raw.test/owner/repo/main/icon/com.test.ext.one.png');
    });

    test('an absolute URL from the index wins over the derived one', () {
      // Same reason apkUrl honours its absolute form: newer indexes publish
      // to a location that cannot be rebuilt from the base.
      final e = _entry(
        pkg: 'com.test.ext.one',
        base: 'https://raw.test/owner/repo/main',
        absoluteIconUrl: 'https://cdn.test/icons/one.png',
      );
      expect(e.iconUrl, 'https://cdn.test/icons/one.png');
    });
  });

  test('MihonRepo.parseIndex carries resources.iconUrl through', () {
    const json = '''
    {"extensionList":{"extensions":[{
      "name":"Test",
      "packageName":"com.test.manga",
      "versionName":"1.2",
      "versionCode":"7",
      "resources":{
        "apkUrl":"https://cdn.test/releases/ext-v1.2.apk",
        "iconUrl":"https://cdn.test/icons/manga.png"
      },
      "sources":[{"id":"9","language":"en","name":"Test","homeUrl":"https://t.test"}]
    }]}}
    ''';
    final entries = MihonRepo.parseIndex(json, repoBaseUrl: 'https://raw.test/o/r/repo');
    expect(entries, hasLength(1));
    expect(entries.single.iconUrl, 'https://cdn.test/icons/manga.png');
  });

  test('a Mihon entry with no iconUrl falls back to the repo convention', () {
    const json = '''
    {"extensionList":{"extensions":[{
      "name":"Test",
      "packageName":"com.test.manga",
      "versionName":"1.2",
      "versionCode":"7",
      "resources":{"apkUrl":"https://cdn.test/releases/ext-v1.2.apk"},
      "sources":[]
    }]}}
    ''';
    final entries = MihonRepo.parseIndex(json, repoBaseUrl: 'https://raw.test/o/r/repo');
    expect(entries.single.iconUrl, 'https://raw.test/o/r/repo/icon/com.test.manga.png');
  });

  group('SourceIconStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('source_icon_store_test');
      Hive.init(tempDir.path);
      await Hive.openBox<String>(SourceIconStore.boxName);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('recordAll stores each entry by package name', () {
      SourceIconStore.recordAll([
        _entry(pkg: 'com.a', base: 'https://raw.test/o/r/main'),
        _entry(pkg: 'com.b', base: 'https://raw.test/o/r/main'),
      ]);
      expect(SourceIconStore.urlFor('com.a'), 'https://raw.test/o/r/main/icon/com.a.png');
      expect(SourceIconStore.urlFor('com.b'), 'https://raw.test/o/r/main/icon/com.b.png');
    });

    test('a package never seen in any index has no icon', () {
      SourceIconStore.recordAll([_entry(pkg: 'com.a', base: 'https://raw.test/o/r/main')]);
      expect(SourceIconStore.urlFor('com.unknown'), isNull);
    });

    test('a later index overwrites an earlier URL for the same package', () {
      SourceIconStore.recordAll([_entry(pkg: 'com.a', base: 'https://old.test/o/r/main')]);
      SourceIconStore.recordAll([_entry(pkg: 'com.a', base: 'https://new.test/o/r/main')]);
      expect(SourceIconStore.urlFor('com.a'), 'https://new.test/o/r/main/icon/com.a.png');
    });

    test('an empty stored value reads as no icon, not as an empty URL', () {
      // An empty string would be handed to CachedNetworkImage as a real URL
      // and render a broken tile instead of the letter.
      Hive.box<String>(SourceIconStore.boxName).put('com.blank', '');
      expect(SourceIconStore.urlFor('com.blank'), isNull);
    });
  });

  group('SourceIconStore with no box open', () {
    test('reads and writes are no-ops rather than crashes', () {
      // The picker builds on every sheet open, including before the boot step
      // that opens this box has run. A cosmetic icon must never throw there.
      expect(Hive.isBoxOpen(SourceIconStore.boxName), isFalse);
      expect(() => SourceIconStore.recordAll([
            _entry(pkg: 'com.a', base: 'https://raw.test/o/r/main'),
          ]), returnsNormally);
      expect(SourceIconStore.urlFor('com.a'), isNull);
    });
  });
}
