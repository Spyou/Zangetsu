import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';

void main() {
  test('pagination preserves Idlix categories with spaces', () {
    for (final name in [
      'Movie Terbaru',
      'TV Series Terbaru',
      'Amazon Prime',
      'Apple TV+',
      'HBO',
      'Netflix',
    ]) {
      const data =
          'https://source.test/api/series?page=%d&limit=36&sort=createdAt';
      final category = csMainPageCategory(csMainPageCategoryId(name, data));
      expect(category.name, name);
      expect(category.data, data);
    }
  });

  test('category names and opaque data round-trip without rewriting', () {
    for (final value in [
      (name: 'Recently added 日本語', data: '/browse?label=TV Shows&quote="new"'),
      (name: '[Popular] specials', data: ''),
      (name: '  Category  ', data: ' data with spaces '),
    ]) {
      expect(
        csMainPageCategory(csMainPageCategoryId(value.name, value.data)),
        value,
      );
    }
  });

  test('older category IDs keep their existing pagination behavior', () {
    expect(csMainPageCategory('Popular https://source.test/path with spaces'), (
      name: 'Popular',
      data: 'https://source.test/path with spaces',
    ));
    expect(csMainPageCategory('Popular'), (name: 'Popular', data: ''));
    expect(csMainPageCategory('Popular '), (name: 'Popular', data: ''));
  });
}
