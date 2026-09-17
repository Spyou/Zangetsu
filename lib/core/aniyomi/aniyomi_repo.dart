import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../hive/source_icon_store.dart';

/// A single anime source entry within a repo index entry.
class AniyomiRepoSource {
  const AniyomiRepoSource({
    required this.id,
    required this.lang,
    required this.name,
    required this.baseUrl,
  });

  final int id;
  final String lang;
  final String name;
  final String baseUrl;

  factory AniyomiRepoSource.fromJson(Map<String, dynamic> json) {
    return AniyomiRepoSource(
      id: (json['id'] as num).toInt(),
      lang: (json['lang'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      baseUrl: (json['baseUrl'] as String?) ?? '',
    );
  }
}

/// One extension entry from an Aniyomi repository `index.min.json`.
///
/// [apkUrl] is computed from [repoBaseUrl] and [apk] and is not stored in the
/// JSON itself.
class AniyomiRepoEntry {
  AniyomiRepoEntry({
    required this.name,
    required this.pkg,
    required this.apk,
    required this.lang,
    required this.version,
    required this.code,
    required this.nsfw,
    required this.sources,
    required String repoBaseUrl,
    String absoluteApkUrl = '',
    String absoluteIconUrl = '',
  })  : apkUrl = absoluteApkUrl.startsWith('http')
            ? absoluteApkUrl
            : '${AniyomiRepo.normalizeBase(repoBaseUrl)}/apk/$apk',
        iconUrl = absoluteIconUrl.startsWith('http')
            ? absoluteIconUrl
            : '${AniyomiRepo.normalizeBase(repoBaseUrl)}/icon/$pkg.png';

  final String name;
  final String pkg;
  final String apk;
  final String lang;
  final String version;
  final int code;

  /// [nsfw] is stored as 0/1 int in `index.min.json`; mapped to bool here.
  final bool nsfw;
  final List<AniyomiRepoSource> sources;

  /// Full URL to download the extension APK.
  ///
  /// Normally derived from the repo base + [apk]
  /// (`https://raw.githubusercontent.com/owner/repo/branch/apk/ext-v1.0.apk`),
  /// which is where repos have historically kept their APKs. When the index
  /// carries an absolute link of its own that wins instead: Keiyoushi now
  /// publishes to GitHub Releases under a per-build tag
  /// (`.../releases/download/88e1412-0/ext-v1.6.4.apk`) that cannot be
  /// reconstructed from the base — rebuilding the old path 404s on all ~1400
  /// of its extensions, so nothing installs.
  final String apkUrl;

  /// Full URL to the extension's icon.
  ///
  /// Repos keep these in an `icon/` folder named after the package, which is
  /// how the picker gets a real logo instead of a letter tile. The newer
  /// index carries its own absolute link (same reason as [apkUrl]) and that
  /// wins when present. Not every repo publishes icons — a 404 here is
  /// expected and just falls back to the letter.
  final String iconUrl;
}

/// Utilities for reading Aniyomi extension repository index files.
class AniyomiRepo {
  /// Normalises a repo base URL to the DIRECTORY that holds `index.min.json`
  /// and the `apk/` folder. Users (and older saved repos) sometimes store the
  /// full index URL (`.../main/index.min.json`) instead of the directory
  /// (`.../main`); left as-is that produces a broken `.../index.min.json/apk/…`
  /// download URL that 404s on every mirror. Strips a trailing index filename
  /// — `/index.min.json`, `/index.json` or `/index.pb` — and any trailing
  /// slash. Shared with Mihon, which prefers `index.pb`.
  static String normalizeBase(String base) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    // People paste the link to the index file itself, not the folder holding
    // it, so strip a trailing index filename. Listed longest-first so
    // `index.min.json` isn't half-matched by `index.json`. `index.pb` belongs
    // here too — it's the file the fetcher now prefers, so it's the most
    // likely thing to be pasted; leaving it out meant the app asked for
    // `.../index.pb/index.pb` and the repo just 404'd.
    for (final name in const [
      '/index.min.json',
      '/index.json',
      '/index.pb',
    ]) {
      if (b.endsWith(name)) {
        b = b.substring(0, b.length - name.length);
        break;
      }
    }
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /// Parses an `index.min.json` JSON array string into a list of
  /// [AniyomiRepoEntry].
  ///
  /// Malformed individual entries are skipped; a totally invalid [json] string
  /// returns an empty list. Never throws.
  static List<AniyomiRepoEntry> parseIndex(
    String json, {
    required String repoBaseUrl,
  }) {
    final entries = <AniyomiRepoEntry>[];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      for (final raw in list) {
        try {
          final m = raw as Map<String, dynamic>;
          final rawSources = m['sources'];
          final sources = <AniyomiRepoSource>[];
          if (rawSources is List) {
            for (final s in rawSources) {
              try {
                sources.add(
                  AniyomiRepoSource.fromJson(s as Map<String, dynamic>),
                );
              } catch (_) {
                // skip malformed source entry
              }
            }
          }
          entries.add(
            AniyomiRepoEntry(
              name: (m['name'] as String?) ?? '',
              pkg: (m['pkg'] as String?) ?? '',
              apk: (m['apk'] as String?) ?? '',
              lang: (m['lang'] as String?) ?? '',
              version: (m['version'] as String?) ?? '',
              code: (m['code'] as num?)?.toInt() ?? 0,
              nsfw: ((m['nsfw'] as num?)?.toInt() ?? 0) != 0,
              sources: sources,
              repoBaseUrl: repoBaseUrl,
            ),
          );
        } catch (_) {
          // skip malformed entry; continue with the rest
        }
      }
    } catch (_) {
      // totally invalid JSON — return empty
    }
    return entries;
  }

  /// Fetches and parses `index.min.json` from [repoBaseUrl].
  ///
  /// When [repoBaseUrl] is a `raw.githubusercontent.com` URL and the primary
  /// fetch fails, a jsDelivr mirror is tried automatically. Non-githubusercontent
  /// base URLs skip the fallback. Never throws — returns an empty list on total
  /// failure.
  static Future<List<AniyomiRepoEntry>> fetchIndex(String repoBaseUrl) async {
    final dio = GetIt.instance<Dio>();
    final base = normalizeBase(repoBaseUrl);
    final primaryUrl = '$base/index.min.json';

    String? jsDelivrUrl() {
      final uri = Uri.tryParse(primaryUrl);
      if (uri == null) return null;
      if (uri.host != 'raw.githubusercontent.com') return null;
      // Path segments: ['', owner, repo, branch, ...rest]
      final segs = uri.pathSegments;
      if (segs.length < 3) return null;
      final owner = segs[0];
      final repo = segs[1];
      final branch = segs[2];
      return 'https://gcore.jsdelivr.net/gh/$owner/$repo@$branch/index.min.json';
    }

    String? rawJson;
    try {
      final resp = await dio.get<String>(primaryUrl);
      if ((resp.statusCode ?? 0) < 300 && resp.data != null) {
        rawJson = resp.data;
      }
    } catch (_) {
      // primary failed — try fallback below
    }

    if (rawJson == null) {
      final fallback = jsDelivrUrl();
      if (fallback != null) {
        try {
          final resp = await dio.get<String>(fallback);
          if ((resp.statusCode ?? 0) < 300 && resp.data != null) {
            rawJson = resp.data;
          }
        } catch (_) {
          // fallback also failed
        }
      }
    }

    if (rawJson == null || rawJson.isEmpty) return [];
    final entries = parseIndex(rawJson, repoBaseUrl: base);
    // The index is the only place an extension's logo is named, so keep the
    // icon URLs on the way past — the source picker has no other way to get
    // one for an installed extension.
    SourceIconStore.recordAll(entries);
    return entries;
  }
}
