import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/stremio/stremio_configuration_merge.dart';

Map<String, dynamic> config(
  List<Map<String, dynamic>> items, {
  List<String> deleted = const [],
}) => {
  'version': 1,
  'installations': items,
  'aliases': <String, String>{},
  'defaultMetadataRemoved': false,
  'deleted': deleted,
};
Map<String, dynamic> addon(
  String id,
  String digest, {
  bool enabled = true,
  int position = 0,
}) => {
  'url': 'https://addon.test/$digest',
  'metadata': {
    'id': id,
    'urlDigest': digest,
    'enabled': enabled,
    'position': position,
  },
};
void main() {
  test('refreshing an addon preserves its updated manifest metadata', () {
    final base = config([addon('stremio_a', 'a')]);
    (base['installations'][0]['metadata'] as Map)['version'] = '1';
    final local = config([addon('stremio_a', 'a')]);
    (local['installations'][0]['metadata'] as Map)['version'] = '2';
    final merged = mergeStremioConfiguration(base, local, base);
    expect(merged['installations'][0]['metadata']['version'], '2');
  });

  test('hiding different catalogues on two devices preserves both choices', () {
    final base = config([addon('stremio_a', 'a')]);
    (base['installations'][0]['metadata'] as Map)['hiddenCatalogs'] =
        <String>[];
    final local = config([addon('stremio_a', 'a')]);
    (local['installations'][0]['metadata'] as Map)['hiddenCatalogs'] = [
      'local',
    ];
    final remote = config([addon('stremio_a', 'a')]);
    (remote['installations'][0]['metadata'] as Map)['hiddenCatalogs'] = [
      'remote',
    ];
    final merged = mergeStremioConfiguration(base, local, remote);
    expect(
      merged['installations'][0]['metadata']['hiddenCatalogs'],
      containsAll(['local', 'remote']),
    );
  });

  test('an explicit reinstall after observing a deletion is allowed', () {
    final base = config([], deleted: ['a']);
    final result = mergeStremioConfiguration(
      base,
      config([addon('stremio_new', 'a')]),
      config([], deleted: ['a']),
    );
    expect((result['installations'] as List), hasLength(1));
    expect(result['deleted'], isNot(contains('a')));
  });
  test('concurrent URL changes do not create duplicate installation IDs', () {
    final base = config([addon('stremio_a', 'old')]);
    final result = mergeStremioConfiguration(
      base,
      config([addon('stremio_a', 'local-new')]),
      config([addon('stremio_a', 'remote-new')]),
    );
    expect((result['installations'] as List), hasLength(1));
    expect(
      (result['installations'] as List).single['metadata']['urlDigest'],
      'remote-new',
    );
  });
  test(
    'a deletion wins over an offline edit and is not resurrected on first sync',
    () {
      final original = addon('stremio_a', 'a');
      final base = config([original]);
      final remote = config([], deleted: ['a']);
      final local = config([addon('stremio_a', 'a', enabled: false)]);
      expect(
        mergeStremioConfiguration(base, local, remote)['installations'],
        isEmpty,
      );
      expect(
        mergeStremioConfiguration(null, local, remote)['installations'],
        isEmpty,
      );
    },
  );
  test('concurrent changes to different fields are retained', () {
    final base = config([addon('stremio_a', 'a')]);
    final local = config([addon('stremio_a', 'a', enabled: false)]);
    final remote = config([addon('stremio_a', 'a', position: 1)]);
    final result = mergeStremioConfiguration(base, local, remote);
    final metadata = (result['installations'] as List).single['metadata'];
    expect(metadata['enabled'], isFalse);
    expect(metadata['position'], 1);
  });
  test('a duplicate addon retains both saved origin IDs through aliases', () {
    final result = mergeStremioConfiguration(
      null,
      config([addon('stremio_local', 'a')]),
      config([addon('stremio_remote', 'a')]),
    );
    expect((result['installations'] as List).length, 1);
    expect(result['aliases'], {'stremio_local': 'stremio_remote'});
  });
  test('local removal does not remove a different addon added remotely', () {
    final base = config([addon('stremio_a', 'a')]);
    final result = mergeStremioConfiguration(
      base,
      config([]),
      config([addon('stremio_a', 'a'), addon('stremio_b', 'b')]),
    );
    expect(
      (result['installations'] as List).single['metadata']['id'],
      'stremio_b',
    );
    expect(result['deleted'], contains('a'));
  });
}
