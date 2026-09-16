import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/page_file_cache.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('page_file_cache_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  PageFileCache cache({
    int maxBytes = 256 * 1024 * 1024,
    Future<Uint8List?> Function(String archivePath, int index)? readCbzEntry,
    Future<Uint8List?> Function(String channel, int sourceId, String url)?
    fetchNativeBytes,
    Future<File?> Function(String url)? lookupCachedFile,
  }) {
    return PageFileCache(
      dir: dir,
      maxBytes: maxBytes,
      readCbzEntry: readCbzEntry,
      fetchNativeBytes: fetchNativeBytes,
      lookupCachedFile: lookupCachedFile ?? (url) async => null,
    );
  }

  test('loose local file resolves to itself, not copied into the cache', () async {
    final local = File('${dir.path}/page.jpg')..writeAsBytesSync([1, 2, 3]);
    final c = cache();

    final f = await c.fileFor(local.path, null);

    expect(f?.path, local.path);
    // Only the file we created ourselves should exist in the dir — a copy
    // would show up as a second entry.
    final entries = await dir.list().toList();
    expect(entries.length, 1);
  });

  test('missing local file returns null rather than throwing', () async {
    final c = cache();
    final f = await c.fileFor('${dir.path}/does_not_exist.jpg', null);
    expect(f, isNull);
  });

  test('http url with nothing cached returns null and does not download', () async {
    var lookups = 0;
    final c = cache(
      lookupCachedFile: (url) async {
        lookups++;
        return null;
      },
    );

    final f = await c.fileFor('https://example.com/page.jpg', null);

    expect(f, isNull);
    expect(lookups, 1);
  });

  test('the same url twice returns the same path', () async {
    var reads = 0;
    final c = cache(
      readCbzEntry: (path, index) async {
        reads++;
        return Uint8List.fromList([1, 2, 3]);
      },
    );
    const url = 'cbz:/some/Chapter 1.cbz#2';

    final first = await c.fileFor(url, null);
    final second = await c.fileFor(url, null);

    expect(first, isNotNull);
    expect(second?.path, first?.path);
    // A cache hit shouldn't re-read the archive entry.
    expect(reads, 1);
  });

  test('trim() deletes oldest-first until under the cap', () async {
    final a = File('${dir.path}/a.img')..writeAsBytesSync([0, 0, 0, 0]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final b = File('${dir.path}/b.img')..writeAsBytesSync([0, 0, 0, 0]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final c = File('${dir.path}/c.img')..writeAsBytesSync([0, 0, 0, 0]);

    // Three 4-byte files; cap fits two of them.
    final pfc = cache(maxBytes: 8);
    await pfc.trim();

    expect(await a.exists(), isFalse, reason: 'oldest should be gone');
    expect(await b.exists(), isTrue);
    expect(await c.exists(), isTrue);
  });

  test('clear() empties the cache', () async {
    File('${dir.path}/a.img').writeAsBytesSync([1]);
    File('${dir.path}/b.img').writeAsBytesSync([2]);
    final c = cache();

    await c.clear();

    expect(await dir.list().toList(), isEmpty);
  });

  test('a url with no extension still produces a usable file', () async {
    final c = cache(
      fetchNativeBytes: (channel, sourceId, url) async =>
          Uint8List.fromList([9, 9, 9]),
    );

    final f = await c.fileFor('https://example.com/no-extension-here', {
      'x-mihon-src': '7',
    });

    expect(f, isNotNull);
    expect(await f!.exists(), isTrue);
    expect(await f.readAsBytes(), [9, 9, 9]);
  });
}
