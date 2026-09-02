// AniList answers `description(asHtml:false)` with <br> tags anyway, wrapped in
// real newlines — so the synopsis rendered the tags as text with blank lines
// around them. These are shapes taken from live responses.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/metadata/synopsis.dart';

void main() {
  test('the <br> pair becomes one paragraph break, not three lines', () {
    // Verbatim from graphql.anilist.co for Fullmetal Alchemist: Brotherhood.
    const raw = '"In order for something to be obtained, something of equal '
        'value must be lost."\n<br><br>\nAlchemy is bound by this Law.';

    expect(
      cleanSynopsis(raw),
      '"In order for something to be obtained, something of equal value must '
      'be lost."\n\nAlchemy is bound by this Law.',
    );
  });

  test('a single break stays a single line break', () {
    expect(cleanSynopsis('One<br>Two'), 'One\nTwo');
  });

  test('other tags are dropped but their words are kept', () {
    expect(cleanSynopsis('A <i>very</i> <b>good</b> show'), 'A very good show');
  });

  test('entities are decoded', () {
    expect(cleanSynopsis('Tom &amp; Jerry &quot;quoted&quot;'),
        'Tom & Jerry "quoted"');
  });

  test('AniList markup markers go, the sentence stays', () {
    // Dropping the hidden sentence outright can gut a synopsis that is mostly
    // one, so the marker is what gets removed.
    expect(cleanSynopsis('He wins. ~!Then he dies.!~'), 'He wins. Then he dies.');
    expect(cleanSynopsis('__Note:__ read the manga'), 'Note: read the manga');
  });

  test('runs of blank lines collapse to one', () {
    expect(cleanSynopsis('A<br><br><br><br>B'), 'A\n\nB');
  });

  test('trailing spaces do not leave a ragged edge', () {
    expect(cleanSynopsis('A   \n   \nB'), 'A\n\nB');
  });

  test('nothing to show reads as nothing, not an empty box', () {
    expect(cleanSynopsis(null), isNull);
    expect(cleanSynopsis('   '), isNull);
    expect(cleanSynopsis('<br><br>'), isNull);
  });
}
