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

  test('forItem builds an /open/ link that parse() round-trips', () {
    final webUrl = ShareLink.forItem(item);
    expect(webUrl, contains('/open/'));

    final d = Uri.parse(webUrl).queryParameters['d'];
    expect(d, isNotNull);

    // The site forwards `d` into a zangetsu://open link — parse that back.
    final parsed = ShareLink.parse(Uri.parse('zangetsu://open?d=$d&t=x'));
    expect(parsed, isNotNull);
    expect(parsed!.url, item.url);
    expect(parsed.sourceId, item.sourceId);
    expect(parsed.title, item.title);
    expect(parsed.id, item.id);
    expect(parsed.type, item.type);
  });

  test('parse ignores links that are not zangetsu://open', () {
    expect(ShareLink.parse(Uri.parse('zangetsu://anilist-auth')), isNull);
    expect(
      ShareLink.parse(Uri.parse('https://spyou.github.io/Zangetsu-Site/')),
      isNull,
    );
    expect(ShareLink.parse(Uri.parse('zangetsu://open')), isNull); // no payload
  });
}
