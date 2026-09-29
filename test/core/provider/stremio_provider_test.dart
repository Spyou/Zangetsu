import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/stremio_provider.dart';

void main() {
  test('parses catalogs from a Stremio manifest', () {
    final manifest = StremioManifest.fromJson({
      'id': 'community.kitsu',
      'name': 'Kitsu',
      'catalogs': [
        {
          'type': 'series',
          'id': 'kitsu-popular',
          'name': 'Popular',
          'extra': [
            {'name': 'genre'},
            {'name': 'search'},
          ],
        },
      ],
    });

    expect(manifest.name, 'Kitsu');
    expect(manifest.catalogs.single.type, 'series');
    expect(manifest.catalogs.single.extra, ['genre', 'search']);
  });

  test('ignores malformed catalogs without hiding valid ones', () {
    final manifest = StremioManifest.fromJson({
      'id': 'addon',
      'catalogs': [
        {'type': 'series', 'id': 'valid', 'name': 'Valid'},
        {'type': '', 'id': 'broken'},
        {'id': 'missing-type'},
      ],
    });

    expect(manifest.catalogs, hasLength(1));
    expect(manifest.catalogs.single.id, 'valid');
  });

  test('preserves resource type in catalog item URLs', () {
    expect(
      StremioProvider.normalizeBase('https://addon.test/manifest.json'),
      'https://addon.test',
    );
  });
}
