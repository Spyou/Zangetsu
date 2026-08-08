import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/page_content.dart';

void main() {
  test('PageImage parses url + optional headers', () {
    final list = PageImage.listFromJson([
      {'url': 'https://a/1.jpg'},
      {'url': 'https://a/2.jpg', 'headers': {'Referer': 'https://a/'}},
    ]);
    expect(list, hasLength(2));
    expect(list[0].url, 'https://a/1.jpg');
    expect(list[0].headers, isNull);
    expect(list[1].headers?['Referer'], 'https://a/');
  });

  test('PageImage skips malformed entries', () {
    final list = PageImage.listFromJson([
      {'url': 'https://a/1.jpg'},
      {'nope': true},
      'garbage',
    ]);
    expect(list, hasLength(1));
  });

  test('ChapterText parses html and optional title', () {
    final t = ChapterText.fromJson({'html': '<p>hi</p>', 'title': 'Ch 1'});
    expect(t.html, '<p>hi</p>');
    expect(t.title, 'Ch 1');
    // `text` key accepted as a fallback for plain-text sources.
    expect(ChapterText.fromJson({'text': 'plain'}).html, 'plain');
  });
}
