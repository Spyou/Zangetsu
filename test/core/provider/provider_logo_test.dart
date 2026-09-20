import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/features/sources/bloc/sources_state.dart';

/// Zangetsu's own sources showed the plain letter tile while Aniyomi, Mihon and
/// CloudStream all showed logos. `RepoSource.logo` and [resolveLogoUrl] existed
/// the whole time and simply had no caller — nothing carried the URL from the
/// manifest to the picker. These cover that wiring.

ProviderRepo repoWith(RepoSource s, {String url = 'https://x.dev/r/index.json'}) =>
    ProviderRepo(
      url: url,
      name: 'R',
      description: '',
      lastSyncedAt: DateTime.now(),
      sources: [s],
    );

RepoSource src({String? logo}) => RepoSource(
      id: 'anikoto',
      name: 'AniKoto',
      version: '1.0.0',
      type: 'anime',
      lang: 'en',
      file: 'providers/anikoto.js',
      logo: logo,
    );

void main() {
  group('resolveLogoUrl', () {
    test('a manifest with no logo resolves to null — the letter tile', () {
      final s = src();
      expect(ProviderReposRegistry.resolveLogoUrl(repoWith(s), s), isNull);
    });

    test('an empty logo is treated as none, not as an empty URL', () {
      final s = src(logo: '');
      expect(ProviderReposRegistry.resolveLogoUrl(repoWith(s), s), isNull);
    });

    test('a relative logo is joined against the manifest directory', () {
      final s = src(logo: 'icons/anikoto.png');
      expect(
        ProviderReposRegistry.resolveLogoUrl(repoWith(s), s),
        'https://x.dev/r/icons/anikoto.png',
      );
    });

    test('an absolute logo is left alone', () {
      final s = src(logo: 'https://cdn.example/a.png');
      expect(
        ProviderReposRegistry.resolveLogoUrl(repoWith(s), s),
        'https://cdn.example/a.png',
      );
    });
  });

  group('ProviderRegistryEntry carries the logo', () {
    test('round-trips through json', () {
      final e = ProviderRegistryEntry(
        name: 'anikoto',
        url: 'https://x.dev/r/providers/anikoto.js',
        logoUrl: 'https://x.dev/r/icons/anikoto.png',
      );
      final back = ProviderRegistryEntry.fromJson(e.toJson());
      expect(back.logoUrl, 'https://x.dev/r/icons/anikoto.png');
    });

    test('an entry without one stays empty, and json omits the key', () {
      final e = ProviderRegistryEntry(name: 'anikoto', url: 'u');
      expect(e.logoUrl, '');
      expect(e.toJson().containsKey('logoUrl'), isFalse,
          reason: 'no key = a settings backup is byte-identical to before');
    });

    test('an old backup with no logoUrl still loads', () {
      // Exactly what a backup taken before this field existed looks like.
      final back = ProviderRegistryEntry.fromJson({
        'name': 'anikoto',
        'url': 'u',
        'version': '1.0.0',
        'enabled': true,
      });
      expect(back.logoUrl, '');
      expect(back.name, 'anikoto');
    });

    test('copyWith keeps it when not asked to change it', () {
      final e = ProviderRegistryEntry(name: 'a', url: 'u', logoUrl: 'L');
      expect(e.copyWith(enabled: false).logoUrl, 'L');
    });
  });

  group('manifestLogos backfills sources installed before the field existed',
      () {
    // THE bug the user hit: the logo showed on the Repos tab but not on
    // Installed, because the entry's snapshot is only written at install time
    // and everything on the device predates it. Reading the manifest fixes
    // both old and new in one go.
    final withLogo = src(logo: 'icons/anikoto.png');
    final noLogo = RepoSource(
      id: 'plainone',
      name: 'Plain',
      version: '1.0.0',
      type: 'anime',
      lang: 'en',
      file: 'providers/plainone.js',
    );
    final repo = ProviderRepo(
      url: 'https://x.dev/r/index.json',
      name: 'R',
      description: '',
      lastSyncedAt: DateTime.now(),
      sources: [withLogo, noLogo],
    );

    test('an entry with an EMPTY snapshot still gets the manifest logo', () {
      final state = SourcesState(
        repos: [repo],
        installed: [
          // exactly what is on the device today: installed before logoUrl
          ProviderRegistryEntry(
            name: 'anikoto',
            url: 'https://x.dev/r/providers/anikoto.js',
            originRepoUrl: 'https://x.dev/r/index.json',
          ),
        ],
      );
      final key = ProviderRegistry.providerKey(repo.url, 'anikoto');
      expect(state.installed.single.logoUrl, '', reason: 'no snapshot');
      expect(state.manifestLogos[key], 'https://x.dev/r/icons/anikoto.png');
    });

    test('a source whose manifest declares no logo is absent, not empty', () {
      final state = SourcesState(repos: [repo]);
      final key = ProviderRegistry.providerKey(repo.url, 'plainone');
      expect(state.manifestLogos.containsKey(key), isFalse,
          reason: 'absent means letter tile, and `?? snapshot` can kick in');
    });

    test('no repos at all is empty, not a crash', () {
      expect(const SourcesState().manifestLogos, isEmpty);
    });

    test('keyed by composite key, so two repos with the same id coexist', () {
      final other = ProviderRepo(
        url: 'https://other.dev/index.json',
        name: 'O',
        description: '',
        lastSyncedAt: DateTime.now(),
        sources: [src(logo: 'mine.png')],
      );
      final state = SourcesState(repos: [repo, other]);
      expect(
        state.manifestLogos[ProviderRegistry.providerKey(repo.url, 'anikoto')],
        'https://x.dev/r/icons/anikoto.png',
      );
      expect(
        state.manifestLogos[ProviderRegistry.providerKey(other.url, 'anikoto')],
        'https://other.dev/mine.png',
      );
    });
  });
}
