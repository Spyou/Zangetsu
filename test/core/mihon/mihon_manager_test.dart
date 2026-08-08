import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/mihon/mihon_update.dart';

MihonProvider _src(int id, String pkg, int code) => MihonProvider(
      info: MihonSourceInfo(
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

MihonUpdate _upd(String pkg, int from, int to) => MihonUpdate(
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
  test('idFor namespaces with mihon: not ani:', () {
    expect(MihonManager.idFor(42), 'mihon:42');
    expect(MihonManager.idFor(42), isNot('ani:42'));
  });

  test('register keys sources under mihon:<id> and notifies listeners', () {
    final m = MihonManager();
    var notifications = 0;
    m.addListener(() => notifications++);

    m.register(_src(7, 'com.test.manga', 3));

    expect(notifications, 1);
    expect(m.all, hasLength(1));
    expect(m.get('mihon:7')!.pkg, 'com.test.manga');
    expect(m.get('7'), isNull);
    expect(m.get('ani:7'), isNull);
  });

  test('registerAll replaces same-id entries and only notifies when non-empty', () {
    final m = MihonManager();
    var notifications = 0;
    m.addListener(() => notifications++);

    m.registerAll([]);
    expect(notifications, 0, reason: 'empty batch must not notify');

    m.registerAll([_src(1, 'a', 1), _src(2, 'a', 1)]);
    expect(notifications, 1);
    expect(m.all, hasLength(2));

    // Re-registering the same id replaces rather than duplicates.
    m.registerAll([_src(1, 'a', 2)]);
    expect(m.all, hasLength(2));
    expect(m.get('mihon:1')!.versionCode, 2);
  });

  test('removeWhere drops matching sources and notifies once', () {
    final m = MihonManager()
      ..registerAll([_src(1, 'a', 1), _src(2, 'b', 1), _src(3, 'b', 1)]);
    var notifications = 0;
    m.addListener(() => notifications++);

    m.removeWhere((s) => s.pkg == 'b');

    expect(notifications, 1);
    expect(m.all.map((s) => s.pkg), ['a']);
  });

  test('removeWhere with no match does not notify', () {
    final m = MihonManager()..registerAll([_src(1, 'a', 1)]);
    var notifications = 0;
    m.addListener(() => notifications++);

    m.removeWhere((s) => s.pkg == 'nope');

    expect(notifications, 0);
    expect(m.all, hasLength(1));
  });

  test('installedCodes maps pkg -> versionCode from registered sources', () {
    final m = MihonManager()
      ..register(_src(1, 'a', 20))
      ..register(_src(2, 'a', 20)) // same pkg, second source
      ..register(_src(3, 'b', 5));
    expect(m.installedCodes, {'a': 20, 'b': 5});
  });

  test('checkRepoUpdates stores results, updateFor + updateCount reflect them',
      () async {
    final m = MihonManager()..register(_src(1, 'a', 20));
    m.checkerOverride = (url, codes) async => [_upd('a', 20, 21)];
    final list = await m.checkRepoUpdates('https://r/x');
    expect(list.single.pkg, 'a');
    expect(m.updatesFor('https://r/x').single.availableCode, 21);
    expect(m.updateFor('a')!.availableVersion, '0.0.21');
    expect(m.updateFor('nope'), isNull);
    expect(m.updateCount, 1);
  });

  test('empty result clears any prior updates for that url', () async {
    final m = MihonManager();
    m.checkerOverride = (url, codes) async => [_upd('a', 20, 21)];
    await m.checkRepoUpdates('https://r/x');
    m.checkerOverride = (url, codes) async => const [];
    await m.checkRepoUpdates('https://r/x');
    expect(m.updateCount, 0);
  });

  test('checkRepoUpdates swallows a throwing checker and returns []',
      () async {
    final m = MihonManager();
    m.checkerOverride = (url, codes) async => throw Exception('boom');
    final result = await m.checkRepoUpdates('https://r/x');
    expect(result, isEmpty);
    expect(m.updateCount, 0);
  });

  test('clearUpdatesForPkg removes just that package', () async {
    final m = MihonManager();
    m.checkerOverride = (url, codes) async => [_upd('a', 1, 2), _upd('b', 1, 2)];
    await m.checkRepoUpdates('https://r/x');
    m.clearUpdatesForPkg('a');
    expect(m.updateFor('a'), isNull);
    expect(m.updateFor('b'), isNotNull);
    expect(m.updateCount, 1);
  });

  test('checkAllUpdates is TTL-debounced unless forced', () async {
    final m = MihonManager();
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
