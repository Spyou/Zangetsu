import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/dom_parsing.dart' show isVoidElement;
import 'package:html/parser.dart' as html_parser;

/// One chapter to place in the EPUB, in reading order.
class EpubChapter {
  const EpubChapter({
    required this.title,
    required this.html,
    this.images = const {},
  });

  final String title;
  final String html;

  /// Absolute paths of images this chapter references, by the `src` used.
  final Map<String, String> images;
}

/// Packs downloaded novel chapters into a real EPUB — a zip with a strict
/// layout, well-formed XHTML chapters, and both an EPUB3 nav doc and an
/// EPUB2 `toc.ncx` so older readers can open it too.
///
/// Pure Dart: no Flutter, no Hive, no platform channel, so it's plain-unit
/// testable. Where the file actually gets SAVED (shared storage vs a picked
/// drive) is the caller's problem, same as [ChapterDownloadStore.publish] —
/// this only ever writes to the path it's given.
class EpubWriter {
  /// The title to show for a chapter, given the "include chapter number"
  /// option.
  ///
  /// Sources very often already put the number in the title, and blindly
  /// prepending gave "Chapter 1: Chapter 1 [IMG]" on a real export. So the
  /// number goes on only when it is not there already.
  static String chapterTitle(String title, num? number, {required bool includeNumber}) {
    if (!includeNumber || number == null) return title;
    final n = number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toString();
    // "Chapter 1", "Ch. 1", "Ch 1", "Episode 1", "#1", "1." and bare "1 -"
    // all count as already numbered. The trailing (\D|$) stops "1" matching
    // the start of "10".
    final already = RegExp(
      r'^(chapter|chap|ch|episode|ep|#)?[\s.:#\-]*' +
          RegExp.escape(n) +
          r'(\D|$)',
      caseSensitive: false,
    );
    if (already.hasMatch(title.trimLeft())) return title;
    return 'Chapter $n: $title';
  }

  /// Writes an EPUB to [outPath] and returns the file.
  static Future<File> write({
    required String outPath,
    required String title,
    String? author,
    String? coverPath,
    required List<EpubChapter> chapters,
    void Function(int done, int total)? onProgress,
  }) async {
    final built = <_ChapterBuild>[];
    for (var i = 0; i < chapters.length; i++) {
      built.add(await _buildChapter(chapters[i], i));
      onProgress?.call(i + 1, chapters.length);
    }

    final cover = await _buildCover(coverPath);
    final uuid = _uuidV4();
    final modified = _isoNow();

    final encoder = ZipFileEncoder()..create(outPath);
    try {
      // `mimetype` MUST be the first entry in the zip, uncompressed — an
      // EPUB reader identifies the file by reading exactly that, and
      // `ZipFileEncoder` otherwise defaults every entry to deflate.
      encoder.addArchiveFile(
        ArchiveFile.string('mimetype', _mimetype)
          ..compression = CompressionType.none,
      );
      encoder.addArchiveFile(
        ArchiveFile.string('META-INF/container.xml', _containerXml),
      );
      encoder.addArchiveFile(
        ArchiveFile.string(
          'OEBPS/content.opf',
          _buildOpf(
            uuid: uuid,
            title: title,
            author: author,
            modified: modified,
            chapters: built,
            cover: cover,
          ),
        ),
      );
      encoder.addArchiveFile(
        ArchiveFile.string('OEBPS/nav.xhtml', _buildNav(title, built)),
      );
      encoder.addArchiveFile(
        ArchiveFile.string('OEBPS/toc.ncx', _buildNcx(uuid, title, built)),
      );
      for (final c in built) {
        encoder.addArchiveFile(ArchiveFile.string('OEBPS/${c.href}', c.xhtml));
      }
      for (final c in built) {
        for (final img in c.images) {
          encoder.addArchiveFile(
            ArchiveFile.bytes('OEBPS/${img.href}', img.bytes),
          );
        }
      }
      if (cover != null) {
        encoder.addArchiveFile(
          ArchiveFile.bytes('OEBPS/${cover.href}', cover.bytes),
        );
      }
    } finally {
      await encoder.close();
    }
    return File(outPath);
  }

  static const String _mimetype = 'application/epub+zip';

  static const String _containerXml =
      '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

  // ── One chapter: messy scraped HTML in, well-formed XHTML out ───────────

  static Future<_ChapterBuild> _buildChapter(
    EpubChapter chapter,
    int index,
  ) async {
    final id = 'ch${(index + 1).toString().padLeft(3, '0')}';

    // Only images that actually exist on disk make it into the book — an
    // image that can't be found gets its `<img>` tag dropped, not the whole
    // chapter (see `_writeNode`, which looks it up in this map).
    final hrefBySrc = <String, String>{};
    final images = <_ImageFile>[];
    var n = 0;
    for (final entry in chapter.images.entries) {
      final file = File(entry.value);
      if (!await file.exists()) continue;
      final ext = _extOf(entry.value);
      final href = 'images/${id}_$n$ext';
      hrefBySrc[entry.key] = href;
      images.add(
        _ImageFile(
          id: '${id}_img$n',
          href: href,
          bytes: await file.readAsBytes(),
          mediaType: _imageMediaType(ext),
        ),
      );
      n++;
    }

    // The `html` package's HTML5 tree builder is deliberately lenient — it
    // never throws, and it fixes up exactly the kind of malformed markup a
    // scraped chapter has (unclosed `<br>`, a bare `&`, stray tags). We then
    // walk the resulting DOM ourselves and serialise it as real XHTML,
    // rather than trust a regex over the source string to produce anything
    // a strict e-reader will accept.
    final document = html_parser.parse(chapter.html);
    final buffer = StringBuffer();
    final body = document.body;
    if (body != null) {
      for (final node in body.nodes) {
        _writeNode(buffer, node, hrefBySrc);
      }
    }

    final xhtml =
        '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><meta charset="utf-8"/><title>${_escapeText(chapter.title)}</title></head>
<body>
$buffer
</body>
</html>
''';

    return _ChapterBuild(
      id: id,
      href: '$id.xhtml',
      title: chapter.title,
      xhtml: xhtml,
      images: images,
    );
  }

  static Future<_ImageFile?> _buildCover(String? coverPath) async {
    if (coverPath == null) return null;
    final file = File(coverPath);
    if (!await file.exists()) return null;
    final ext = _extOf(coverPath);
    return _ImageFile(
      id: 'cover-img',
      href: 'images/cover$ext',
      bytes: await file.readAsBytes(),
      mediaType: _imageMediaType(ext),
    );
  }

  // ── DOM → XHTML ──────────────────────────────────────────────────────────

  /// Writes one DOM node as XHTML. `<script>`/`<style>` are dropped whole
  /// (with their children — nothing inside them is ever chapter text), every
  /// `on*` attribute is dropped, void elements self-close, and an `<img>`
  /// whose `src` doesn't resolve in [hrefBySrc] is dropped rather than left
  /// pointing at a file that was never packed.
  static void _writeNode(
    StringBuffer out,
    dom.Node node,
    Map<String, String> hrefBySrc,
  ) {
    if (node is dom.Text) {
      out.write(_escapeText(node.data));
      return;
    }
    if (node is! dom.Element) return; // comments etc. — scrape noise, drop
    final tag = node.localName?.toLowerCase();
    if (tag == null || tag == 'script' || tag == 'style') return;

    if (tag == 'img') {
      final src = node.attributes['src'];
      final href = src == null ? null : hrefBySrc[src];
      if (href == null) return;
      out.write('<img');
      _writeAttrs(out, node, skip: const {'src'});
      out
        ..write(' src="')
        ..write(_escapeAttr(href))
        ..write('"/>');
      return;
    }

    out.write('<$tag');
    _writeAttrs(out, node);
    if (isVoidElement(tag)) {
      out.write('/>');
      return;
    }
    out.write('>');
    for (final child in node.nodes) {
      _writeNode(out, child, hrefBySrc);
    }
    out.write('</$tag>');
  }

  static void _writeAttrs(
    StringBuffer out,
    dom.Element node, {
    Set<String> skip = const {},
  }) {
    for (final entry in node.attributes.entries) {
      final name = entry.key.toString().toLowerCase();
      if (name.startsWith('on') || skip.contains(name)) continue;
      out
        ..write(' ')
        ..write(name)
        ..write('="')
        ..write(_escapeAttr(entry.value))
        ..write('"');
    }
  }

  static String _escapeText(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escapeAttr(String s) =>
      _escapeText(s).replaceAll('"', '&quot;');

  // ── content.opf / nav.xhtml / toc.ncx ───────────────────────────────────

  static String _buildOpf({
    required String uuid,
    required String title,
    String? author,
    required String modified,
    required List<_ChapterBuild> chapters,
    _ImageFile? cover,
  }) {
    final manifest = StringBuffer()
      ..writeln(
        '    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>',
      )
      ..writeln(
        '    <item id="ncx" href="toc.ncx" '
        'media-type="application/x-dtbncx+xml"/>',
      );
    for (final c in chapters) {
      manifest.writeln(
        '    <item id="${c.id}" href="${c.href}" '
        'media-type="application/xhtml+xml"/>',
      );
    }
    for (final c in chapters) {
      for (final img in c.images) {
        manifest.writeln(
          '    <item id="${img.id}" href="${img.href}" '
          'media-type="${img.mediaType}"/>',
        );
      }
    }
    if (cover != null) {
      manifest.writeln(
        '    <item id="${cover.id}" href="${cover.href}" '
        'media-type="${cover.mediaType}" properties="cover-image"/>',
      );
    }

    final spine = StringBuffer();
    for (final c in chapters) {
      spine.writeln('    <itemref idref="${c.id}"/>');
    }

    return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="BookId">urn:uuid:$uuid</dc:identifier>
    <dc:title>${_escapeText(title)}</dc:title>
    <dc:language>en</dc:language>
${author != null ? '    <dc:creator>${_escapeText(author)}</dc:creator>\n' : ''}    <meta property="dcterms:modified">$modified</meta>
${cover != null ? '    <meta name="cover" content="${cover.id}"/>\n' : ''}  </metadata>
  <manifest>
$manifest  </manifest>
  <spine toc="ncx">
$spine  </spine>
</package>
''';
  }

  static String _buildNav(String title, List<_ChapterBuild> chapters) {
    final items = StringBuffer();
    for (final c in chapters) {
      items.writeln(
        '      <li><a href="${c.href}">${_escapeText(c.title)}</a></li>',
      );
    }
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="utf-8"/><title>${_escapeText(title)}</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>${_escapeText(title)}</h1>
    <ol>
$items    </ol>
  </nav>
</body>
</html>
''';
  }

  static String _buildNcx(
    String uuid,
    String title,
    List<_ChapterBuild> chapters,
  ) {
    final navPoints = StringBuffer();
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      navPoints.writeln(
        '    <navPoint id="navPoint-${i + 1}" playOrder="${i + 1}">\n'
        '      <navLabel><text>${_escapeText(c.title)}</text></navLabel>\n'
        '      <content src="${c.href}"/>\n'
        '    </navPoint>',
      );
    }
    return '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:$uuid"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>${_escapeText(title)}</text></docTitle>
  <navMap>
$navPoints  </navMap>
</ncx>
''';
  }

  // ── Small helpers ────────────────────────────────────────────────────────

  static String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    return dot > slash ? path.substring(dot).toLowerCase() : '.jpg';
  }

  static String _imageMediaType(String ext) => switch (ext) {
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    '.svg' => 'image/svg+xml',
    '.bmp' => 'image/bmp',
    _ => 'image/jpeg',
  };

  static String _isoNow() =>
      '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';

  static String _uuidV4() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    String hex(int start, int len) => b
        .sublist(start, start + len)
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 2)}-${hex(6, 2)}-${hex(8, 2)}-${hex(10, 6)}';
  }
}

class _ChapterBuild {
  _ChapterBuild({
    required this.id,
    required this.href,
    required this.title,
    required this.xhtml,
    required this.images,
  });

  final String id;
  final String href;
  final String title;
  final String xhtml;
  final List<_ImageFile> images;
}

class _ImageFile {
  _ImageFile({
    required this.id,
    required this.href,
    required this.bytes,
    required this.mediaType,
  });

  final String id;
  final String href;
  final List<int> bytes;
  final String mediaType;
}
