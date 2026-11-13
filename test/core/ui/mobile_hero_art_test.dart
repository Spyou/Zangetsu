import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/mobile_hero_art.dart';

void main() {
  test(
    'Stremio uses addon background even when its poster is hosted on TMDB',
    () {
      const poster = 'https://image.tmdb.org/t/p/w500/poster.jpg';
      const backdrop = 'https://addon.example/background.jpg';
      expect(mobileHeroArt(poster, backdrop, sourceId: 'stremio'), backdrop);
      expect(mobileHeroArt(poster, null, sourceId: 'stremio'), poster);
      expect(mobileHeroArt(poster, '  ', sourceId: 'stremio'), poster);
      expect(mobileHeroArt(null, null, sourceId: 'stremio'), isNull);
      expect(
        mobileHeroArt(poster, backdrop, sourceId: 'tmdb'),
        contains('/original/poster.jpg'),
      );
    },
  );

  test(
    'wide Stremio heroes keep full-HD decode while other providers stay unchanged',
    () {
      expect(mobileHeroDecodeWidth('stremio', 1080), 1920);
      expect(mobileHeroDecodeWidth('stremio', 2560), 2560);
      expect(mobileHeroDecodeWidth('tmdb', 1080), 1080);
      expect(mobileHeroDecodeWidth('cs:source', 1080), 1080);
    },
  );

  test('detail tint uses the poster then falls back to the backdrop', () {
    const poster = 'https://image.tmdb.org/t/p/w500/poster.jpg';
    const backdrop = 'https://image.tmdb.org/t/p/w780/backdrop.jpg';
    expect(adaptiveArtUrl(poster, backdrop), poster);
    expect(adaptiveArtUrl(null, backdrop), backdrop);
    expect(adaptiveArtUrl('', backdrop), backdrop);
    expect(adaptiveArtUrl('  ', backdrop), backdrop);
    expect(adaptiveArtUrl(poster, null), poster);
    expect(adaptiveArtUrl(null, null), isNull);
    expect(mobileHeroArt(poster, backdrop), contains('/original/poster.jpg'));
  });

  test('uses original-size TMDB portrait art for tall mobile heroes', () {
    expect(
      mobileHeroArt(
        'https://image.tmdb.org/t/p/w500/poster.jpg',
        'https://image.tmdb.org/t/p/w780/backdrop.jpg',
      ),
      'https://image.tmdb.org/t/p/original/poster.jpg',
    );
  });

  test('keeps the wide image when TMDB has no portrait', () {
    expect(
      mobileHeroArt(null, 'https://image.tmdb.org/t/p/w780/backdrop.jpg'),
      'https://image.tmdb.org/t/p/w780/backdrop.jpg',
    );
  });

  test('does not change non-TMDB artwork', () {
    expect(
      mobileHeroArt('https://anime/cover.jpg', 'https://anime/banner.jpg'),
      'https://anime/banner.jpg',
    );
  });
}
