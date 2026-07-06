import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';

AniyomiRepoEntry _entry(String pkg, int code, String version) => AniyomiRepoEntry(
      name: pkg,
      pkg: pkg,
      apk: '$pkg.apk',
      lang: 'en',
      version: version,
      code: code,
      nsfw: false,
      sources: const [],
      repoBaseUrl: 'https://repo.example/x',
    );

void main() {
  final service = AniyomiExtensionService();
  final index = [
    _entry('a', 21, '1.4.21'),
    _entry('b', 5, '0.0.5'),
    _entry('c', 9, '1.0.9'),
  ];
  Future<List<AniyomiRepoEntry>> fakeFetch(String _) async => index;

  test('reports only installed pkgs with a newer code', () async {
    final updates = await service.checkRepoForUpdates(
      'https://repo.example/x',
      {'a': 20, 'b': 5, 'z': 1}, // a outdated, b equal, c not installed, z not in index
      fetchIndex: fakeFetch,
    );
    expect(updates.map((u) => u.pkg), ['a']);
    final u = updates.single;
    expect(u.installedCode, 20);
    expect(u.availableCode, 21);
    expect(u.availableVersion, '1.4.21');
    expect(u.entry.pkg, 'a');
  });

  test('returns empty list when fetch throws', () async {
    final updates = await service.checkRepoForUpdates(
      'https://repo.example/x',
      {'a': 1},
      fetchIndex: (_) async => throw Exception('network'),
    );
    expect(updates, isEmpty);
  });
}
