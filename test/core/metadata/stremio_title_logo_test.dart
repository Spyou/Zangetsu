import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/metadata/title_logo_service.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

const _addonLogo = 'https://art.example/title.png';
const _tmdbLogo = 'https://image.tmdb.org/t/p/w500/title.png';

class _Adapter implements HttpClientAdapter {
  final requests = <Uri>[];
  bool hasLogo = true;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requests.add(options.uri);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return ResponseBody.fromString(
      jsonEncode({
        'logos': [
          if (hasLogo) {'file_path': '/title.png', 'iso_639_1': 'en'},
        ],
      }),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

MediaItem _item({String sourceId = 'stremio', String? logo}) => MediaItem(
  id: 'movie:tt123',
  title: 'Example',
  url: 'stremio://ref?v=1&i=addon&t=movie&m=tt123',
  type: ProviderType.movie,
  sourceId: sourceId,
  tmdbId: 123,
  titleLogo: logo,
);

void main() {
  late Directory temp;
  late _Adapter adapter;
  late TitleLogoService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stremio_title_logo');
    Hive.init(temp.path);
    await Hive.openBox<String>('logo_cache');
    adapter = _Adapter();
    service = TitleLogoService(Dio()..httpClientAdapter = adapter);
  });

  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test('concurrent banner logo lookups share one TMDB request', () async {
    final item = _item(sourceId: 'tmdb');
    final urls = await Future.wait(
      List.generate(3, (_) => service.logoFor(item)),
    );
    expect(urls, everyElement(_tmdbLogo));
    expect(adapter.requests, hasLength(1));
  });

  test('addon logo avoids TMDB and survives a new service instance', () async {
    expect(await service.logoFor(_item(logo: _addonLogo)), _addonLogo);
    final restarted = TitleLogoService(Dio()..httpClientAdapter = adapter);
    expect(await restarted.logoFor(_item()), _addonLogo);
    expect(adapter.requests, isEmpty);
  });

  test('missing addon logo uses the cached TMDB fallback', () async {
    expect(await service.logoFor(_item()), _tmdbLogo);
    expect(await service.logoFor(_item()), _tmdbLogo);
    expect(adapter.requests, hasLength(1));
  });

  test(
    'detail-only addon logos share the metadata lookup and skip TMDB',
    () async {
      var metadataCalls = 0;
      service = TitleLogoService(
        Dio()..httpClientAdapter = adapter,
        addonLogoFor: (_) async {
          metadataCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _addonLogo;
        },
      );
      final urls = await Future.wait(
        List.generate(4, (_) => service.logoFor(_item())),
      );
      expect(urls, everyElement(_addonLogo));
      expect(await service.logoFor(_item()), _addonLogo);
      expect(metadataCalls, 1);
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'prefetch does not request metadata for unseen Stremio titles',
    () async {
      var metadataCalls = 0;
      service = TitleLogoService(
        Dio()..httpClientAdapter = adapter,
        addonLogoFor: (_) async {
          metadataCalls++;
          return _addonLogo;
        },
      );
      await service.prefetch([_item()]);
      expect(metadataCalls, 0);
      expect(adapter.requests, isEmpty);
    },
  );

  test('addon metadata failures still allow TMDB', () async {
    service = TitleLogoService(
      Dio()..httpClientAdapter = adapter,
      addonLogoFor: (_) async => throw StateError('unavailable'),
    );
    expect(await service.logoFor(_item()), _tmdbLogo);
    expect(adapter.requests, hasLength(1));
  });

  test('an available addon logo does not require the disk cache', () async {
    await Hive.close();
    expect(await service.logoFor(_item(logo: _addonLogo)), _addonLogo);
    expect(adapter.requests, isEmpty);
  });

  test('a cached missing TMDB logo never hides new addon artwork', () async {
    adapter.hasLogo = false;
    expect(await service.logoFor(_item()), isNull);
    expect(await service.logoFor(_item(logo: _addonLogo)), _addonLogo);
    expect(adapter.requests, hasLength(1));
  });

  test(
    'broken addon logo falls back once and is not retried this session',
    () async {
      final item = _item(logo: _addonLogo);
      expect(await service.logoFor(item), _addonLogo);
      expect(await service.fallbackFor(item, _addonLogo), _tmdbLogo);
      expect(await service.logoFor(item), _tmdbLogo);
      expect(await service.fallbackFor(item, _tmdbLogo), isNull);
      expect(adapter.requests, hasLength(1));
    },
  );

  test('concurrent Stremio fallback requests share one TMDB lookup', () async {
    final urls = await Future.wait(
      List.generate(6, (_) => service.logoFor(_item())),
    );
    expect(urls, everyElement(_tmdbLogo));
    expect(adapter.requests, hasLength(1));
  });

  test(
    'no available logo returns text fallback without repeating TMDB',
    () async {
      adapter.hasLogo = false;
      expect(await service.logoFor(_item()), isNull);
      expect(await service.logoFor(_item()), isNull);
      expect(adapter.requests, hasLength(1));
    },
  );

  test('invalid addon image schemes use the normal fallback', () async {
    expect(
      await service.logoFor(_item(logo: 'file:///private/logo.png')),
      _tmdbLogo,
    );
    expect(await service.logoFor(_item(logo: '  ')), _tmdbLogo);
    expect(adapter.requests, hasLength(1));
  });

  test(
    'other providers ignore addon logos and retain their TMDB path',
    () async {
      await service.logoFor(_item(logo: _addonLogo));
      final other = _item(sourceId: 'cs:example', logo: _addonLogo);
      expect(await service.logoFor(other), _tmdbLogo);
      expect(await service.fallbackFor(other, _tmdbLogo), isNull);
      expect(adapter.requests, hasLength(1));
    },
  );

  test('runtime logos survive copies without changing saved JSON', () {
    final item = _item(logo: _addonLogo);
    expect(item.copyWith().titleLogo, _addonLogo);
    expect(item.toJson().containsKey('titleLogo'), isFalse);
  });
}
