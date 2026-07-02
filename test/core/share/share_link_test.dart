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
    // Short link: no base64 blob, just the four query params.
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
