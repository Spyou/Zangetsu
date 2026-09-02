// Sharing a title from the metadata catalogue. The link carries the Z Mode
// pseudo-source, which is not an installed source and never can be — the open
// path used to refuse it with "add it in Settings", naming something the
// recipient has no way to install.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/share/share_link.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

MediaItem _zItem(String canonical, {ZKind kind = ZKind.anime}) {
  final c = ZCanonical(kind, canonical);
  return MediaItem(
    id: canonical,
    title: 'Some Title',
    url: ZmodeIds.showUrl(c),
    type: ProviderType.anime,
    sourceId: ZmodeIds.sourceId,
    cover: 'https://x/c.jpg',
  );
}

void main() {
  test('a metadata title survives the share round trip', () {
    final link = ShareLink.forItem(_zItem('mal:1735'));
    final back = ShareLink.parse(
      Uri.parse(link.replaceFirst(RegExp(r'^https?://[^?]*'), 'zangetsu://open')),
    );

    expect(back, isNotNull);
    expect(back!.sourceId, ZmodeIds.sourceId);
    expect(back.url, 'zm://anime/mal:1735');
  });

  test('an unsaved title names no provider', () {
    // Nothing recorded to pass on: the recipient opens it with their own.
    final link = ShareLink.forItem(_zItem('mal:1735'));

    expect(link, contains('s=zm'));
    expect(link, isNot(contains('p=')));
  });

  test('the catalogue you were on carries to the other person', () {
    final item = MediaItem(
      id: 'tmdb:9',
      title: 'A Film',
      url: 'zm://movie/tmdb:9',
      type: ProviderType.movie,
      sourceId: ZmodeIds.sourceId,
      savedFrom: 'Simkl',
    );

    final link = ShareLink.forItem(item);
    final back = ShareLink.parse(
      Uri.parse(link.replaceFirst(RegExp(r'^https?://[^?]*'), 'zangetsu://open')),
    );

    expect(back!.savedFrom, 'Simkl');
  });

  test('a source share is unchanged', () {
    // Source titles carry their source in `s` and have nothing to stamp, so
    // their links must look exactly as they always did.
    final src = MediaItem(
      id: '1',
      title: 'A Show',
      url: 'https://example.test/show/1',
      type: ProviderType.anime,
      sourceId: 'ani:1',
    );

    final link = ShareLink.forItem(src);

    expect(link, contains('s=ani%3A1'));
    expect(link, isNot(contains('p=')));
    final back = ShareLink.parse(
      Uri.parse(link.replaceFirst(RegExp(r'^https?://[^?]*'), 'zangetsu://open')),
    );
    expect(back!.sourceId, 'ani:1');
    expect(back.savedFrom, isNull);
  });

  test('an older link without the provider still opens', () {
    // Shared before this existed: it must resolve, just with the recipient's
    // own provider.
    final back = ShareLink.parse(
      Uri.parse('zangetsu://open?s=zm&u=zm%3A%2F%2Fanime%2Fmal%3A1&t=X'),
    );

    expect(back, isNotNull);
    expect(back!.savedFrom, isNull);
  });

  test('movie and manga kinds keep their kind in the url', () {
    // The kind lives in the url, not in the type flag, so a shared manga does
    // not come back as an anime.
    expect(
      ShareLink.forItem(_zItem('mal:2', kind: ZKind.manga)).contains(
        Uri.encodeComponent('zm://manga/mal:2'),
      ),
      isTrue,
    );
    expect(
      ShareLink.forItem(_zItem('tmdb:9', kind: ZKind.movie)).contains(
        Uri.encodeComponent('zm://movie/tmdb:9'),
      ),
      isTrue,
    );
  });
}
