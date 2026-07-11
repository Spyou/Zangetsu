import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/sources/sources_search_field.dart';

void main() {
  test('sourceSearchMatches: name substring, case-insensitive', () {
    expect(sourceSearchMatches('anime', 'AnimeWorld'), isTrue);
    expect(sourceSearchMatches('WORLD', 'AnimeWorld'), isTrue);
    expect(sourceSearchMatches('naruto', 'AnimeWorld'), isFalse);
  });

  test('sourceSearchMatches: blank query matches everything', () {
    expect(sourceSearchMatches('', 'Whatever'), isTrue);
    expect(sourceSearchMatches('   ', 'Whatever'), isTrue);
  });

  test('sourceSearchMatches: exact lang code matches', () {
    expect(sourceSearchMatches('id', 'DramaCool', 'id'), isTrue);
    expect(sourceSearchMatches('en', 'DramaCool', 'id'), isFalse);
    // lang is exact-match only — "d" matches lang "id" neither (but it does
    // match the name here, so use a name without it).
    expect(sourceSearchMatches('x', 'DramaCool', 'id'), isFalse);
  });
}
