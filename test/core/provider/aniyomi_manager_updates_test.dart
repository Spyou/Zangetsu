import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/aniyomi/aniyomi_update.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

AniyomiProvider _prov(int id, String pkg, int code) => AniyomiProvider(
      info: AniyomiSourceInfo(
        id: id,
        name: 'S$id',
        lang: 'en',
        baseUrl: '',
        pkg: pkg,
        nsfw: false,
        version: '0.0.$code',
        versionCode: code,
      ),
    );

AniyomiUpdate _upd(String pkg, int from, int to) => AniyomiUpdate(
      pkg: pkg,
      name: pkg,
      installedCode: from,
      availableCode: to,
      availableVersion: '0.0.$to',
      entry: AniyomiRepoEntry(
        name: pkg, pkg: pkg, apk: '$pkg.apk', lang: 'en',
        version: '0.0.$to', code: to, nsfw: false, sources: const [],
        repoBaseUrl: 'https://r/x',
      ),
    );

void main() {
  test('installedCodes maps pkg -> versionCode from registered providers', () {
    final m = AniyomiManager()
      ..register(_prov(1, 'a', 20))
      ..register(_prov(2, 'a', 20)) // same pkg, second source
      ..register(_prov(3, 'b', 5));
    expect(m.installedCodes, {'a': 20, 'b': 5});
  });

  test('checkRepoUpdates stores results, updateFor + updateCount reflect them', () async {
    final m = AniyomiManager()..register(_prov(1, 'a', 20));
    m.checkerOverride = (url, codes) async => [_upd('a', 20, 21)];
    final list = await m.checkRepoUpdates('https://r/x');
    expect(list.single.pkg, 'a');
    expect(m.updatesFor('https://r/x').single.availableCode, 21);
    expect(m.updateFor('a')!.availableVersion, '0.0.21');
    expect(m.updateFor('nope'), isNull);
    expect(m.updateCount, 1);
  });

  test('empty result clears any prior updates for that url', () async {
    final m = AniyomiManager();
    m.checkerOverride = (url, codes) async => [_upd('a', 20, 21)];
    await m.checkRepoUpdates('https://r/x');
    m.checkerOverride = (url, codes) async => const [];
    await m.checkRepoUpdates('https://r/x');
    expect(m.updateCount, 0);
  });

  test('clearUpdatesForPkg removes just that package', () async {
    final m = AniyomiManager();
    m.checkerOverride = (url, codes) async => [_upd('a', 1, 2), _upd('b', 1, 2)];
    await m.checkRepoUpdates('https://r/x');
    m.clearUpdatesForPkg('a');
    expect(m.updateFor('a'), isNull);
    expect(m.updateFor('b'), isNotNull);
    expect(m.updateCount, 1);
  });

  test('checkAllUpdates is TTL-debounced unless forced', () async {
    final m = AniyomiManager();
    var calls = 0;
    m.checkerOverride = (url, codes) async {
      calls++;
      return const [];
    };
    await m.checkAllUpdates(['https://r/x']);
    await m.checkAllUpdates(['https://r/x']); // within TTL -> skipped
    expect(calls, 1);
    await m.checkAllUpdates(['https://r/x'], force: true);
    expect(calls, 2);
  });
}
