import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../aniyomi/aniyomi_repo.dart';
import 'mihon_extension_service.dart' show githubMirrors;
import 'mihon_pb_index.dart';

/// Raised when a repo index was reachable but unusable (wrong format, invalid
/// JSON) or unreachable on every URL we tried.
///
/// This exists because [AniyomiRepo.parseIndex] swallows every failure and
/// returns an empty list, which renders as the perfectly innocent-looking
/// "No extensions found in this repo." — a silent lie when the real problem is
/// a format the app doesn't understand. `_MihonRepoSectionState._fetchCatalog`
/// catches this and shows `Failed to load: <message>` instead.
class MihonRepoException implements Exception {
  const MihonRepoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads Mihon (manga) extension repository indexes.
///
/// The manga twin of [AniyomiRepo], and NOT a thin wrapper around it: Mihon
/// repos publish a different file in a different shape.
///
/// * `index.json` — what Mihon 0.20+ repos (keiyoushi and friends) publish:
///   an object `{name, badgeLabel, signingKey, contact, extensionList}` whose
///   `extensionList.extensions[]` holds the extensions.
/// * `index.min.json` — the legacy Tachiyomi/Aniyomi array. keiyoushi still
///   serves one, but has gutted it to two "your app is outdated" stubs with a
///   placeholder APK, so reading it installs nothing. Third-party repos that
///   never migrated may still publish only this file, so it stays as a
///   fallback — parsed by [AniyomiRepo.parseIndex], unchanged.
///
/// Both shapes map onto [AniyomiRepoEntry] so nothing downstream (install,
/// update check, the repo tab) had to learn a second entry type.
class MihonRepo {
  /// Index file names in preference order. `index.pb` first: it's the same data
  /// as `index.json` (keiyoushi regenerates both in one commit) but ~13x smaller
  /// on the wire, and `repo.json` advertises it as the canonical `index_v2`. A
  /// pb that won't fetch or decode falls through to `index.json`; `index.min.json`
  /// is the legacy-only last resort.
  static const List<String> _indexFiles = [
    'index.pb',
    'index.json',
    'index.min.json',
  ];

  /// Parses either index shape into [AniyomiRepoEntry]s, picking the parser by
  /// the JSON's top-level type (array = legacy, object = Mihon).
  ///
  /// Throws [MihonRepoException] when [json] is not valid JSON or is neither
  /// shape. Individual malformed entries are still skipped rather than failing
  /// the whole repo.
  static List<AniyomiRepoEntry> parseIndex(
    String json, {
    required String repoBaseUrl,
  }) {
    final base = AniyomiRepo.normalizeBase(repoBaseUrl);

    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      throw const MihonRepoException("the repo index isn't valid JSON");
    }

    // Legacy Tachiyomi/Aniyomi `index.min.json`: a bare array of entries.
    if (decoded is List) {
      return AniyomiRepo.parseIndex(json, repoBaseUrl: base);
    }

    if (decoded is Map) {
      final extensionList = decoded['extensionList'];
      final raw = extensionList is Map ? extensionList['extensions'] : null;
      if (raw is List) {
        final entries = <AniyomiRepoEntry>[];
        for (final e in raw) {
          final entry = _entryFrom(e, base);
          if (entry != null) entries.add(entry);
        }
        return entries;
      }
    }

    throw const MihonRepoException(
      'unrecognised repo index format — expected a Mihon index.json object '
      'with extensionList.extensions, or a legacy index.min.json array',
    );
  }

  /// Maps one `extensionList.extensions[]` object onto an [AniyomiRepoEntry],
  /// or null when it is too broken to install (no package name / no APK).
  static AniyomiRepoEntry? _entryFrom(Object? raw, String base) {
    if (raw is! Map) return null;

    final pkg = _str(raw['packageName']);
    // `resources.apkUrl` is an absolute jsDelivr URL, but [AniyomiRepoEntry]
    // builds its download URL as `<base>/apk/<apk>` — so keep the filename
    // only and let it resolve against the repo the user actually added.
    final apk = _str(
      (raw['resources'] is Map ? (raw['resources'] as Map)['apkUrl'] : null),
    ).split('?').first.split('/').last;
    if (pkg.isEmpty || apk.isEmpty) return null;

    final sources = <AniyomiRepoSource>[];
    final rawSources = raw['sources'];
    if (rawSources is List) {
      for (final s in rawSources) {
        if (s is! Map) continue;
        sources.add(
          AniyomiRepoSource(
            // Source ids are decimal strings here (they overflow JS numbers),
            // and the keys are `language`/`homeUrl`, not `lang`/`baseUrl`.
            id: int.tryParse(_str(s['id'])) ?? 0,
            lang: _str(s['language']),
            name: _str(s['name']),
            baseUrl: _str(s['homeUrl']),
          ),
        );
      }
    }

    final lang = sources.isNotEmpty && sources.first.lang.isNotEmpty
        ? sources.first.lang
        : 'all';

    return AniyomiRepoEntry(
      name: _str(raw['name']),
      pkg: pkg,
      apk: apk,
      lang: lang,
      version: _str(raw['versionName']),
      // A String in this schema ("4"), a number in the legacy one.
      code: _int(raw['versionCode']),
      // CONTENT_WARNING_MIXED exists too; only the explicit NSFW flag counts.
      nsfw: _str(raw['contentWarning']) == 'CONTENT_WARNING_NSFW',
      sources: sources,
      repoBaseUrl: base,
    );
  }

  /// Decodes a Mihon `index.pb` (gzip-compressed protobuf) into entries, reusing
  /// the same [_entryFrom] mapping as `index.json` — the two carry identical
  /// data. Throws (via [decodeMihonPbIndex]) on malformed bytes so [fetchIndex]
  /// can fall back to `index.json`.
  static List<AniyomiRepoEntry> parsePbIndex(
    List<int> bytes, {
    required String repoBaseUrl,
  }) {
    final base = AniyomiRepo.normalizeBase(repoBaseUrl);
    final entries = <AniyomiRepoEntry>[];
    for (final e in decodeMihonPbIndex(bytes)) {
      final entry = _entryFrom(e, base);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  static String _str(Object? v) => v == null ? '' : '$v';

  static int _int(Object? v) =>
      v is num ? v.toInt() : int.tryParse(_str(v).trim()) ?? 0;

  /// Fetches and parses the index for [repoBaseUrl].
  ///
  /// Tries `index.pb`, then `index.json`, then `index.min.json`, each one direct
  /// first and then through the GitHub-raw mirrors — raw.githubusercontent.com is
  /// blocked on some devices (see `aniyomi_extension_service.dart`'s note).
  ///
  /// Only an *unreachable* URL (network error, 404, any non-2xx, empty body)
  /// falls through to the next one, so `index.min.json` is reached exactly
  /// when the repo never published an `index.json` — the case that fallback
  /// exists for. An `index.json` that answers 2xx with something unparseable
  /// throws instead: that's a schema change, and it must be seen.
  ///
  /// Unlike [AniyomiRepo.fetchIndex] this THROWS a [MihonRepoException] when
  /// nothing could be fetched or parsed, so the UI shows a failure instead of
  /// an empty repo.
  static Future<List<AniyomiRepoEntry>> fetchIndex(String repoBaseUrl) async {
    final dio = GetIt.instance<Dio>();
    final base = AniyomiRepo.normalizeBase(repoBaseUrl);
    // jsDelivr answers with `application/json`, which Dio would helpfully
    // decode into a Map and then fail to cast to String — force plain text.
    final options = Options(responseType: ResponseType.plain);

    Object? lastError;
    for (final file in _indexFiles) {
      final isPb = file.endsWith('.pb');
      final direct = '$base/$file';
      for (final url in <String>[direct, ...githubMirrors(direct)]) {
        if (isPb) {
          List<int>? bytes;
          try {
            final resp = await dio.get<List<int>>(
              url,
              options: Options(responseType: ResponseType.bytes),
            );
            if ((resp.statusCode ?? 0) < 300) bytes = resp.data;
          } catch (e) {
            lastError = e;
            continue;
          }
          if (bytes == null || bytes.isEmpty) continue;
          // Unlike index.json below, a pb that decodes badly does NOT fail the
          // repo: it's just a smaller mirror of the identical index.json, so on
          // any decode error (schema drift, corrupt gzip) fall through to JSON.
          try {
            return parsePbIndex(bytes, repoBaseUrl: base);
          } catch (e) {
            lastError = e;
            break; // give up on pb mirrors; move on to index.json
          }
        }

        String? body;
        try {
          final resp = await dio.get<String>(url, options: options);
          if ((resp.statusCode ?? 0) < 300) body = resp.data;
        } catch (e) {
          lastError = e;
          continue;
        }
        if (body == null || body.trim().isEmpty) continue;
        // Reachable and non-empty: this IS the repo's index, so a parse
        // failure is the answer and it propagates. Falling through to
        // index.min.json here would hide the next schema change behind
        // whatever legacy stub the repo still serves — which is exactly how
        // the two "Outdated App" rows got shipped in the first place.
        return parseIndex(body, repoBaseUrl: base);
      }
    }

    throw MihonRepoException(
      "couldn't read this repo's index — ${lastError ?? 'no response'}",
    );
  }
}
