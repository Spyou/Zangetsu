import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/novel_paginator.dart';

void main() {
  // TextPainter needs the test binding's font/rendering set up.
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 14, height: 1.4);

  TextSpan plainChapter(String text) =>
      TextSpan(style: style, children: [TextSpan(text: text)]);

  final longText = List.generate(
    200,
    (i) => 'Sentence number $i has quite a few words so the page fills up.',
  ).join(' ');

  double heightOf(TextSpan span, double width) {
    final tp = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: width);
    final h = tp.height;
    tp.dispose();
    return h;
  }

  group('paginateSpans', () {
    test('a long chapter yields more than one page for a small page size', () {
      final pages = paginateSpans(
        plainChapter(longText),
        pageSize: const Size(180, 200),
        style: style,
      );
      expect(pages.length, greaterThan(1));
    });

    test('concatenating every page equals the source text — no character '
        'dropped or duplicated', () {
      final source = plainChapter(longText);
      final pages = paginateSpans(
        source,
        pageSize: const Size(180, 200),
        style: style,
      );
      final joined = pages.map((p) => p.toPlainText()).join();
      expect(joined, source.toPlainText());
    });

    test('no page overflows: each page re-laid-out at page width is no taller '
        'than the page height', () {
      const pageSize = Size(180, 200);
      final pages = paginateSpans(
        plainChapter(longText),
        pageSize: pageSize,
        style: style,
      );
      for (final page in pages) {
        expect(
          heightOf(page, pageSize.width),
          lessThanOrEqualTo(pageSize.height + 0.5),
        );
      }
    });

    test('a chapter that fits on one page returns exactly one page', () {
      final pages = paginateSpans(
        plainChapter('Just a short line.'),
        pageSize: const Size(1000, 1000),
        style: style,
      );
      expect(pages, hasLength(1));
      expect(pages.single.toPlainText(), 'Just a short line.');
    });

    test('inline styling is preserved: a bold sub-span stays bold on whatever '
        'page it lands on', () {
      final chapter = TextSpan(
        style: style,
        children: [
          TextSpan(text: 'plain lead in text '),
          TextSpan(
            text: 'BOLDWORD',
            style: style.copyWith(fontWeight: FontWeight.bold),
          ),
          const TextSpan(text: ' and plain trailing text.'),
        ],
      );
      final pages = paginateSpans(
        chapter,
        pageSize: const Size(140, 120),
        style: style,
      );

      // Whole text is still there.
      expect(
        pages.map((p) => p.toPlainText()).join(),
        chapter.toPlainText(),
      );

      var foundBold = false;
      for (final page in pages) {
        for (final child in page.children ?? const <InlineSpan>[]) {
          if (child is TextSpan &&
              (child.text ?? '').contains('BOLDWORD') &&
              child.style?.fontWeight == FontWeight.bold) {
            foundBold = true;
          }
        }
      }
      expect(foundBold, isTrue);
    });
  });
}
