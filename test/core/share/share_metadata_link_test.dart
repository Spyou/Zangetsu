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

  test('the link names no provider, only the title', () {
    // Deliberate: the id is provider-neutral, so the recipient opens it with
    // THEIR provider. Encoding the sender's would tell a MAL user to go and
    // use AniList for no reason.
    final link = ShareLink.forItem(_zItem('mal:1735'));

    expect(link, contains('s=zm'));
    for (final p in ['anilist', 'myanimelist', 'tmdb=', 'simkl']) {
      expect(link.toLowerCase(), isNot(contains(p)));
    }
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
