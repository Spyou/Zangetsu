import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';

void main() {
  group('AniyomiRepo.normalizeBase', () {
    test('strips a trailing /index.min.json to the directory', () {
      expect(
        AniyomiRepo.normalizeBase(
          'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main/index.min.json',
        ),
        'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main',
      );
    });

    test('strips a trailing /index.json', () {
      expect(
        AniyomiRepo.normalizeBase('https://example.com/repo/index.json'),
        'https://example.com/repo',
      );
    });

    test('strips a trailing slash', () {
      expect(
        AniyomiRepo.normalizeBase('https://example.com/repo/'),
        'https://example.com/repo',
      );
    });

    test('leaves a clean directory base unchanged', () {
      expect(
        AniyomiRepo.normalizeBase(
          'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main',
        ),
        'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main',
      );
    });
  });

  test('apkUrl is built from the normalized base even when base is the index URL', () {
    // The bug: base saved as the full index URL produced
    // ".../main/index.min.json/apk/x.apk" which 404s on every mirror.
    const json = '''
[{"name":"X","pkg":"x","apk":"x-v1.apk","lang":"all","version":"1","code":1,"nsfw":0,"sources":[]}]
''';
    final entries = AniyomiRepo.parseIndex(
      json,
      repoBaseUrl:
          'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main/index.min.json',
    );
    expect(entries, hasLength(1));
    expect(
      entries.single.apkUrl,
      'https://raw.githubusercontent.com/salmanbappi/extensions-repo/main/apk/x-v1.apk',
    );
  });
}
