import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  test('ProviderInfo round-trips anime type', () {
    final json = {
      'name': 'Example',
      'lang': 'en',
      'baseUrl': 'https://example.test',
      'logo': 'https://example.test/logo.png',
      'type': 'anime',
      'version': '1.0.0',
    };
    final info = ProviderInfo.fromJson(json);
    expect(info.name, 'Example');
    expect(info.type, ProviderType.anime);
    expect(info.toJson()['type'], 'anime');
  });

  test('ProviderInfo defaults unknown type to anime-safe parse', () {
    final info = ProviderInfo.fromJson({
      'name': 'X', 'lang': 'en', 'baseUrl': 'https://x.test', 'type': 'movie',
    });
    expect(info.type, ProviderType.movie);
    expect(info.logo, isNull);
  });
}
