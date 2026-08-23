import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/subtitle_translate_service.dart';

/// Offline tests for the translate response shape.
///
/// These exist because the endpoint broke silently: Google started answering
/// `client=gtx` with an HTML rate-limit page instead of JSON, every line fell
/// back to its original text, and nothing anywhere said so. The old test was
/// network-backed and accepted the untranslated fallback, so it stayed green
/// through the outage. These don't touch the network and don't accept it.
void main() {
  const parse = SubtitleTranslateService.parseTranslatedBody;

  test('reads the translated text out of a real response', () {
    // Captured from the live endpoint.
    const body =
        '[[["Nunca pensé que terminaría así.",'
        '"I never thought it would end like this.",null,null,3]],'
        'null,"en",null,null,null,1,[],[["en"],null,[1],["en"]]]';
    expect(parse(body), 'Nunca pensé que terminaría así.');
  });

  test('joins a long line split across several segments', () {
    const body = '[[["Part one. ","Part one. ",null,null,3],'
        '["Part two.","Part two.",null,null,3]],null,"en"]';
    expect(parse(body), 'Part one. Part two.');
  });

  test("the rate-limit page reads as 'no translation', not as text", () {
    // The actual failure: an HTML page where JSON was expected. Returning the
    // page (or throwing) would put markup into someone's subtitles.
    const html = '<html><head><title>Sorry...</title></head><body>'
        'We\'re sorry... but your computer or network may be sending '
        'automated queries.</body></html>';
    expect(parse(html), isNull);
  });

  test('empty, null and malformed bodies are null rather than a crash', () {
    expect(parse(null), isNull);
    expect(parse(''), isNull);
    expect(parse('   '), isNull);
    expect(parse('not json at all'), isNull);
    expect(parse('{"unexpected":"object"}'), isNull);
    expect(parse('[]'), isNull);
    expect(parse('[null]'), isNull);
  });
}
