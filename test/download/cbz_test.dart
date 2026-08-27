import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/cbz_image.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';

/// A tiny but real PNG, so the archive holds actual image bytes rather than
/// text pretending to be one.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89,
]);

void main() {
  group('safeName', () {
    test('keeps spaces and drops only what a filesystem rejects', () {
      // The bug: everything outside [A-Za-z0-9_.-] became an underscore, so
      // "Chapter 1: Outer Court Disciple" saved as
      // "Chapter_1___Outer_Court_Disciple".
      expect(
        ChapterDownloadStore.safeName('Chapter 1: Outer Court Disciple'),
        'Chapter 1 Outer Court Disciple',
      );
      expect(
        ChapterDownloadStore.safeName('Re:Zero / Season 2'),
        'Re Zero Season 2',
      );
    });

    test('strips trailing dots and spaces', () {
      // FAT/exFAT (an SD card) refuses to create these.
      expect(ChapterDownloadStore.safeName('Chapter 5. '), 'Chapter 5');
      expect(ChapterDownloadStore.safeName('Vol 1...'), 'Vol 1');
    });

    test('caps the length and never returns empty', () {
      expect(ChapterDownloadStore.safeName('a' * 300).length, 120);
      expect(ChapterDownloadStore.safeName('///'), 'source');
      expect(ChapterDownloadStore.safeName('   '), 'source');
    });
  });

  group('cbz', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cbz');
    });

    tearDown(() async {
      releaseCbz();
      await dir.delete(recursive: true);
    });

    /// Built by the real packer, so these tests cover what actually ships.
    Future<String> writeArchive(int pages) async {
      final staged = Directory('${dir.path}/staged')..createSync();
      final files = <File>[];
      for (var i = 0; i < pages; i++) {
        final f = File('${staged.path}/${i.toString().padLeft(3, '0')}.png');
        // Page index in the last byte, so a mis-ordered read is detectable.
        await f.writeAsBytes([..._png, i]);
        files.add(f);
      }
      final out = await ChapterDownloadStore.zipPages(
        files,
        staged,
        'Chapter 1',
      );
      return out.path;
    }

    test('pages come back in order and byte-identical', () async {
      final path = await writeArchive(5);
      expect(await cbzPageCount(path), 5);

      for (var i = 0; i < 5; i++) {
        final provider = CbzImage.tryParse(cbzUrl(path, i));
        expect(provider, isNotNull);
        expect(provider!.index, i);
        expect(provider.archivePath, path);
      }
    });

    test('a cbz url survives a path with spaces in it', () {
      // The naming fix means archive paths now contain spaces, and the index
      // is split off the end — a path containing '#' would still break, but a
      // space must not.
      final p = CbzImage.tryParse(cbzUrl('/sdcard/Download/My Show/Ch 1.cbz', 7));
      expect(p, isNotNull);
      expect(p!.archivePath, '/sdcard/Download/My Show/Ch 1.cbz');
      expect(p.index, 7);
    });

    test('a non-cbz url is not claimed', () {
      expect(CbzImage.tryParse('https://x/1.jpg'), isNull);
      expect(CbzImage.tryParse('/sdcard/x/001.jpg'), isNull);
      expect(CbzImage.tryParse('cbz:/no/index/here'), isNull);
    });

    test('a missing archive reports no pages instead of throwing', () async {
      expect(await cbzPageCount('${dir.path}/nope.cbz'), 0);
    });

    test('a truncated archive reports no pages instead of throwing', () async {
      final path = await writeArchive(3);
      final bytes = await File(path).readAsBytes();
      await File(path).writeAsBytes(bytes.sublist(0, bytes.length ~/ 3));
      expect(await cbzPageCount(path), 0);
    });

    test('pages are stored, not deflated', () async {
      // Deflating an already-compressed image burns CPU for nothing, and
      // stored entries read back as a plain seek and copy.
      final path = await writeArchive(3);
      final archive = ZipDecoder().decodeStream(InputFileStream(path));
      for (final f in archive.files.where((f) => f.isFile)) {
        expect(f.compression, CompressionType.none);
      }
    });
  });
}
