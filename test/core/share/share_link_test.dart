import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/share/share_link.dart';

void main() {
  const item = MediaItem(
    id: 'abc123',
    title: 'Bleach: Thousand-Year Blood War',
    url: 'https://example.com/anime/bleach?x=1&y=2',
    type: ProviderType.anime,
    sourceId: 'allanime',
    cover: 'https://img.example/x.jpg',
  );

  test('forItem builds a short /open/ link that parse() round-trips', () {
    final webUrl = ShareLink.forItem(item);
    expect(webUrl, contains('/open/'));
    // Short link: plain query params, no base64 blob.
    expect(webUrl, isNot(contains('d=')));

    // The site forwards the same query params into a zangetsu://open link.
    final web = Uri.parse(webUrl);
    final deepLink =
        Uri.parse('zangetsu://open').replace(queryParameters: web.queryParameters);
    final parsed = ShareLink.parse(deepLink);
    expect(parsed, isNotNull);
    expect(parsed!.url, item.url);
    expect(parsed.sourceId, item.sourceId);
    expect(parsed.title, item.title);
    expect(parsed.type, item.type);
    // Carried so the opened Detail has art before the source's detail call
    // returns — and at all, for a source that omits the cover there.
    expect(parsed.cover, item.cover);
  });

  test('a link shared without a cover still parses', () {
    const noCover = MediaItem(
      id: 'abc123',
      title: 'Bleach: Thousand-Year Blood War',
      url: 'https://example.com/anime/bleach',
      type: ProviderType.anime,
      sourceId: 'allanime',
    );
    final web = Uri.parse(ShareLink.forItem(noCover));
    expect(web.queryParameters.containsKey('c'), isFalse);

    final parsed = ShareLink.parse(
      Uri.parse('zangetsu://open').replace(queryParameters: web.queryParameters),
    );
    // Older builds shared links without `c`; Detail falls back to the source.
    expect(parsed, isNotNull);
    expect(parsed!.cover, isNull);
    expect(parsed.url, noCover.url);
  });

  test('parse ignores links that are not zangetsu://open', () {
    expect(ShareLink.parse(Uri.parse('zangetsu://anilist-auth')), isNull);
    expect(
      ShareLink.parse(Uri.parse('https://spyou.github.io/Zangetsu-Site/')),
      isNull,
    );
    expect(ShareLink.parse(Uri.parse('zangetsu://open')), isNull); // no source/url
  });
}
