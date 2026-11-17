import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/stremio/stremio_home_cache.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';

class _Secrets implements StremioSecretStore {
  final values = <String, String>{};
  bool unavailable = false;
  @override
  Future<String?> read(String key) async {
    if (unavailable) throw StateError('locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (unavailable) throw StateError('locked');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _row = HomeSection(
  title: 'Private catalogue',
  items: [
    MediaItem(
      id: 'movie:tt1',
      title: 'Title',
      sourceId: 'stremio',
      type: ProviderType.movie,
      url: 'stremio://ref?v=1&i=test&t=movie&m=tt1',
      cover: 'https://images.example/private-token/poster.jpg',
      banner: 'https://images.example/backdrop.jpg',
      titleLogo: 'https://images.example/logo.png',
      posterShape: 'landscape',
      landscapePoster: 'https://images.example/wide.jpg',
    ),
  ],
  more: BrowseMore(
    sourceId: 'stremio',
    kind: 'stremio_catalog',
    categoryId: '{"i":"test","t":"movie","c":"top"}',
  ),
);

void main() {
  late Directory directory;
  late _Secrets secrets;
  late DateTime now;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('stremio-home-cache');
    Hive.init(directory.path);
    secrets = _Secrets();
    now = DateTime(2026, 11, 17);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  StremioHomeCache cache() =>
      StremioHomeCache(secrets: secrets, clock: () => now);

  test(
    'restart restores artwork and paging without plaintext URLs on disk',
    () async {
      await cache().write('account/profile/config', [_row]);
      await Hive.close();
      final raw = await File(
        '${directory.path}/${StremioHomeCache.boxName}.hive',
      ).readAsBytes();
      expect(latin1.decode(raw), isNot(contains('private-token')));
      expect(latin1.decode(raw), isNot(contains('Private catalogue')));
      final rows = await cache().read('account/profile/config');
      expect(rows, hasLength(1));
      expect(rows!.single.items.single, _row.items.single);
      expect(rows.single.more!.categoryId, _row.more!.categoryId);
      expect(rows.single.items.single.toJson(), isNot(contains('posterShape')));
    },
  );

  test(
    'snapshot keeps whole first pages so See All cannot skip titles',
    () async {
      final row = HomeSection(
        title: _row.title,
        more: _row.more,
        items: [
          for (var i = 0; i < 80; i++)
            MediaItem(
              id: 'movie:tt$i',
              title: 'Title $i',
              url: 'stremio://ref?v=1&i=test&t=movie&m=tt$i',
              type: ProviderType.movie,
              sourceId: 'stremio',
            ),
        ],
      );
      final store = cache();
      await store.write('scope', [row]);
      final restored = (await store.read('scope'))!.single;
      expect(restored.items, hasLength(80));
      expect(restored.items[30].title, 'Title 30');
      expect(restored.items.last.title, 'Title 79');
      expect(restored.more!.categoryId, row.more!.categoryId);
    },
  );

  test(
    'the same cache instance recovers after secure storage unlocks',
    () async {
      final store = cache();
      secrets.unavailable = true;
      await store.write('scope', [_row]);
      secrets.unavailable = false;
      await store.write('scope', [_row]);
      expect(await store.read('scope'), hasLength(1));
    },
  );

  test('a later empty write cannot be undone by earlier encryption', () async {
    final store = cache();
    final older = store.write('scope', [_row]);
    final newer = store.write('scope', []);
    await Future.wait([older, newer]);
    expect(await store.read('scope'), isNull);
  });

  test('a successful empty catalogue removes its old preview', () async {
    final store = cache();
    await store.write('scope', [_row]);
    await store.write('scope', []);
    expect(await store.read('scope'), isNull);
  });

  test(
    'account profile and changed configuration cannot reuse another preview',
    () async {
      final addon = StremioInstallation(
        id: 'test',
        name: 'Test',
        version: '1',
        manifestId: 'org.test',
        types: const ['movie'],
        idPrefixes: const ['tt'],
        resources: const [],
        catalogs: const [],
        enabled: true,
        revision: 1,
        createdAt: 1,
        urlDigest: 'url-digest',
      );
      String key(String owner, String profile, StremioInstallation item) =>
          StremioHomeCache.scope(
            owner: owner,
            profile: profile,
            addons: [item],
          );
      final saved = key('owner-a', 'profile-a', addon);
      await cache().write(saved, [_row]);
      expect(await cache().read(key('owner-b', 'profile-a', addon)), isNull);
      expect(await cache().read(key('owner-a', 'profile-b', addon)), isNull);
      expect(
        await cache().read(
          key('owner-a', 'profile-a', addon.copyWith(revision: 2)),
        ),
        isNull,
      );
      expect(
        await cache().read(
          key(
            'owner-a',
            'profile-a',
            addon.copyWith(hiddenCatalogs: ['movie:top']),
          ),
        ),
        isNull,
      );
    },
  );

  test(
    'expired corrupt and unavailable-key snapshots fail as cache misses',
    () async {
      await cache().write('scope', [_row]);
      now = now.add(const Duration(days: 8));
      expect(await cache().read('scope'), isNull);
      now = now.subtract(const Duration(days: 8));
      final box = Hive.box(StremioHomeCache.boxName);
      await box.put(box.keys.single, {'data': 'corrupt'});
      expect(await cache().read('scope'), isNull);
      secrets.unavailable = true;
      expect(await cache().read('scope'), isNull);
      await cache().write('other', [_row]);
    },
  );

  test(
    'snapshots are bounded and copying encrypted entries cannot cross scopes',
    () async {
      final store = cache();
      await store.write('scope-a', [_row]);
      await store.write('scope-b', [_row]);
      final box = Hive.box(StremioHomeCache.boxName);
      final a = sha256.convert(utf8.encode('scope-a')).toString();
      final b = sha256.convert(utf8.encode('scope-b')).toString();
      await box.put(b, box.get(a));
      expect(await store.read('scope-b'), isNull);
      for (var i = 0; i < 12; i++) {
        now = now.add(const Duration(seconds: 1));
        await store.write('scope-$i', [_row]);
      }
      expect(box.length, lessThanOrEqualTo(8));
    },
  );
}
