import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/share/share_link.dart';

void main() {
  group('ShareLink.watchUrl', () {
    test('builds the https open link for the Discord button', () {
      final url = ShareLink.watchUrl(
        sourceId: 'cs:hiAnime',
        url: 'https://hianime.to/watch/one-piece-100',
        title: 'One Piece',
        type: ProviderType.anime,
      );
      expect(url, startsWith('https://zangetsu.online/open/'));
      expect(url, contains('s=cs%3AhiAnime'));
      expect(url, contains('One+Piece'));
    });

    test('null when the title identity is incomplete', () {
      expect(
        ShareLink.watchUrl(
          sourceId: '',
          url: 'https://hianime.to/watch/x',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: null,
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: '',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
    });
  });
}
