import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  test('labels and reading flags', () {
    expect(ContentMode.anime.label, 'Anime');
    expect(ContentMode.manga.label, 'Manga');
    expect(ContentMode.novel.label, 'Novel');
    expect(ContentMode.anime.isReading, isFalse);
    expect(ContentMode.manga.isReading, isTrue);
    expect(ContentMode.novel.isReading, isTrue);
  });

  test('every mode has its own icon', () {
    final icons = ContentMode.values.map((m) => m.icon).toSet();
    expect(icons.length, ContentMode.values.length);
  });

  test('mode ↔ provider type matching', () {
    // Anime mode owns both existing video types (anime + movie sources).
    expect(ContentMode.anime.matchesProvider(ProviderType.anime), isTrue);
    expect(ContentMode.anime.matchesProvider(ProviderType.movie), isTrue);
    expect(ContentMode.anime.matchesProvider(ProviderType.manga), isFalse);
    expect(ContentMode.manga.matchesProvider(ProviderType.manga), isTrue);
    expect(ContentMode.novel.matchesProvider(ProviderType.novel), isTrue);
    expect(ContentMode.manga.matchesProvider(ProviderType.novel), isFalse);
  });

  test('new ProviderType members round-trip by name', () {
    expect(ProviderType.values.byName('manga'), ProviderType.manga);
    expect(ProviderType.values.byName('novel'), ProviderType.novel);
  });
}
