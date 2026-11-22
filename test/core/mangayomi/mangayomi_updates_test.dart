import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mangayomi/mangayomi_manager.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

final _repository = Uri.parse('https://repo.example.com/index.json');

MangayomiSource _source({required int id, String version = '1.0.0'}) =>
    MangayomiSource.fromManifest({
      'id': id,
      'name': 'Source $id',
      'baseUrl': 'https://source$id.example.com',
      'sourceCodeUrl': 'https://cdn.example.com/$id.dart',
      'version': version,
      'itemType': 0,
      'sourceCodeLanguage': 0,
      'lang': 'en',
    }, _repository);

InstalledMangayomiSource _installed(MangayomiSource source) =>
    InstalledMangayomiSource(source, File('/dev/null'));

void main() {
  test('outdated: version mismatch reports the catalogue source', () {
    final old = _source(id: 1, version: '1.0.0');
    final updated = _source(id: 1, version: '1.0.1');
    final out = mangayomiOutdatedSources([_installed(old)], [updated]);
    expect(out.single.version, '1.0.1');
  });

  test('outdated: same version is up to date', () {
    final current = _source(id: 1);
    expect(mangayomiOutdatedSources([_installed(current)], [current]), isEmpty);
  });

  test('outdated: older catalogue version is not offered as an update', () {
    final installed = _source(id: 1, version: '2.0.0');
    final older = _source(id: 1, version: '1.9.9');
    expect(mangayomiOutdatedSources([_installed(installed)], [older]), isEmpty);
    expect(mangayomiVersionIsNewer(older.version, installed.version), isFalse);
  });

  test('outdated: installed source missing from catalogue is left alone', () {
    final orphaned = _source(id: 2);
    final other = _source(id: 3, version: '9.9.9');
    expect(mangayomiOutdatedSources([_installed(orphaned)], [other]), isEmpty);
  });
}
