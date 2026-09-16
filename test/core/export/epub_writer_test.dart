import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:watch_app/core/export/epub_writer.dart';

/// Parses with a REAL XML parser, which is the only check worth making here:
/// an e-reader rejects the WHOLE file over one unescaped `&` or mismatched
/// tag, and a hand-rolled tag-balance walk does not catch either. If this
/// throws, the EPUB is broken.
void _assertWellFormedXml(String xml) {
  XmlDocument.parse(xml);
}

Archive _readEpub(File f) => ZipDecoder().decodeStream(InputFileStream(f.path));

String _entryString(Archive a, String name) =>
    utf8.decode(a.findFile(name)!.content as List<int>);

void main() {
  _titleTests();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('epub_writer_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('mimetype is the first entry, stored, with exact bytes', () async {
    final out = await EpubWriter.write(
      outPath: '${dir.path}/book.epub',
      title: 'A Book',
      chapters: const [EpubChapter(title: 'One', html: '<p>Hello</p>')],
    );
    final archive = _readEpub(out);
    final first = archive.files.first;
    expect(first.name, 'mimetype');
    expect(first.compression, CompressionType.none);
    expect(first.content, utf8.encode('application/epub+zip'));
  });

  test(
    'container.xml points at content.opf, and the opf lists every chapter '
    'in the spine in order',
    () async {
      final out = await EpubWriter.write(
        outPath: '${dir.path}/book.epub',
        title: 'A Book',
        chapters: const [
          EpubChapter(title: 'First', html: '<p>1</p>'),
          EpubChapter(title: 'Second', html: '<p>2</p>'),
          EpubChapter(title: 'Third', html: '<p>3</p>'),
        ],
      );
      final archive = _readEpub(out);

      final container = _entryString(archive, 'META-INF/container.xml');
      expect(container, contains('full-path="OEBPS/content.opf"'));

      final opf = _entryString(archive, 'OEBPS/content.opf');
      // The spine lists ch001/ch002/ch003, in that order.
      final spineOrder = RegExp(r'idref="(ch\d+)"')
          .allMatches(opf)
          .map((m) => m.group(1))
          .toList();
      expect(spineOrder, ['ch001', 'ch002', 'ch003']);

      // And each file in the spine really does hold the chapter that belongs
      // at that position — not just three arbitrary spine entries.
      for (final (i, expected) in ['First', 'Second', 'Third'].indexed) {
        final ch = _entryString(archive, 'OEBPS/ch${(i + 1).toString().padLeft(3, '0')}.xhtml');
        expect(ch, contains('<title>$expected</title>'));
      }
    },
  );

  test('messy input comes out well-formed', () async {
    final out = await EpubWriter.write(
      outPath: '${dir.path}/book.epub',
      title: 'A Book',
      chapters: const [
        EpubChapter(title: 'Messy', html: '<p>a & b<br>unclosed'),
      ],
    );
    final archive = _readEpub(out);
    final ch = _entryString(archive, 'OEBPS/ch001.xhtml');

    _assertWellFormedXml(ch);
    // The bare '&' is escaped and the void <br> self-closes — the two exact
    // things that break a strict reader if the DOM walk regresses.
    expect(ch, contains('a &amp; b'));
    expect(ch, contains('<br/>'));
    expect(ch, isNot(contains('<br>')));
  });

  test('an image that cannot be found is dropped, chapter still exports', () async {
    final out = await EpubWriter.write(
      outPath: '${dir.path}/book.epub',
      title: 'A Book',
      chapters: [
        EpubChapter(
          title: 'Pic',
          html: '<p>See <img src="missing.jpg"> here</p>',
          images: {'missing.jpg': '${dir.path}/does_not_exist.jpg'},
        ),
      ],
    );
    final archive = _readEpub(out);
    final ch = _entryString(archive, 'OEBPS/ch001.xhtml');

    expect(ch, isNot(contains('<img')));
    expect(ch, contains('See'));
    expect(ch, contains('here'));

    // No manifest entry for an image that was never packed.
    final opf = _entryString(archive, 'OEBPS/content.opf');
    expect(opf, isNot(contains('images/')));
  });

  test('a present image is packed, rewritten to its OEBPS path, and kept', () async {
    final imgPath = '${dir.path}/source.jpg';
    await File(imgPath).writeAsBytes([1, 2, 3, 4]);
    final out = await EpubWriter.write(
      outPath: '${dir.path}/book.epub',
      title: 'A Book',
      chapters: [
        EpubChapter(
          title: 'Pic',
          html: '<p>See <img src="pic.jpg" alt="x"> here</p>',
          images: {'pic.jpg': imgPath},
        ),
      ],
    );
    final archive = _readEpub(out);
    final ch = _entryString(archive, 'OEBPS/ch001.xhtml');
    expect(ch, contains('<img alt="x" src="images/ch001_0.jpg"/>'));

    final packed = archive.findFile('OEBPS/images/ch001_0.jpg');
    expect(packed, isNotNull);
    expect(packed!.content, [1, 2, 3, 4]);

    final opf = _entryString(archive, 'OEBPS/content.opf');
    expect(opf, contains('href="images/ch001_0.jpg"'));
  });

  test('"include chapter number" changes the chapter title, on or off', () async {
    // The dialog builds the numbered/plain title before handing chapters to
    // the writer — this proves the writer actually threads whatever title
    // it's given through to the chapter's <title>, both ways.
    Future<String> titleFor(String chapterTitle) async {
      final out = await EpubWriter.write(
        outPath: '${dir.path}/${chapterTitle.hashCode}.epub',
        title: 'A Book',
        chapters: [EpubChapter(title: chapterTitle, html: '<p>x</p>')],
      );
      return _entryString(_readEpub(out), 'OEBPS/ch001.xhtml');
    }

    final numbered = await titleFor('Chapter 5: Into the Woods');
    final plain = await titleFor('Into the Woods');

    expect(numbered, contains('<title>Chapter 5: Into the Woods</title>'));
    expect(plain, contains('<title>Into the Woods</title>'));
    expect(numbered, isNot(equals(plain)));
  });

  test('a range export contains only that range', () async {
    final all = List.generate(
      5,
      (i) => EpubChapter(title: 'Chapter ${i + 1}', html: '<p>text ${i + 1}</p>'),
    );
    // Only chapters 2 and 3 (index 1..2) — a picked middle range, not "all".
    final out = await EpubWriter.write(
      outPath: '${dir.path}/book.epub',
      title: 'A Book',
      chapters: all.sublist(1, 3),
    );
    final archive = _readEpub(out);
    final opf = _entryString(archive, 'OEBPS/content.opf');

    final spineOrder = RegExp(r'idref="(ch\d+)"')
        .allMatches(opf)
        .map((m) => m.group(1))
        .toList();
    expect(spineOrder, ['ch001', 'ch002']);
    expect(archive.findFile('OEBPS/ch003.xhtml'), isNull);

    final first = _entryString(archive, 'OEBPS/ch001.xhtml');
    final second = _entryString(archive, 'OEBPS/ch002.xhtml');
    expect(first, contains('Chapter 2'));
    expect(second, contains('Chapter 3'));
    expect(first, isNot(contains('text 1')));
    expect(second, isNot(contains('text 4')));
  });
}

void _titleTests() {
  group('chapterTitle', () {
    test('does not repeat a number the title already carries', () {
      // The real export produced "Chapter 1: Chapter 1 [IMG]" before this.
      expect(
        EpubWriter.chapterTitle('Chapter 1 [IMG]', 1, includeNumber: true),
        'Chapter 1 [IMG]',
      );
      for (final t in ['Ch. 2 - Start', 'Episode 3', '#4 Hello', '5. Onwards']) {
        final n = int.parse(RegExp(r'\d+').firstMatch(t)!.group(0)!);
        expect(
          EpubWriter.chapterTitle(t, n, includeNumber: true),
          t,
          reason: '"$t" already says $n',
        );
      }
    });

    test('adds the number when the title does not have it', () {
      expect(
        EpubWriter.chapterTitle('The First Battle', 1, includeNumber: true),
        'Chapter 1: The First Battle',
      );
      // "10" must not be treated as already-numbered by a chapter 1.
      expect(
        EpubWriter.chapterTitle('10 Reasons', 1, includeNumber: true),
        'Chapter 1: 10 Reasons',
      );
    });

    test('off, or no number, leaves the title alone', () {
      expect(
        EpubWriter.chapterTitle('Anything', 7, includeNumber: false),
        'Anything',
      );
      expect(
        EpubWriter.chapterTitle('Anything', null, includeNumber: true),
        'Anything',
      );
    });
  });
}
