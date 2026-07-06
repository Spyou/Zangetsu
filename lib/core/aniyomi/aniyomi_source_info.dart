/// A single source entry as returned by the native `listSources` bridge call.
///
/// Field names match the JSON keys emitted by `AniyomiBridge.sourcesJson()`:
/// `id`, `name`, `lang`, `nsfw`, `pkg`, `baseUrl`, `headers`, `version`,
/// `versionCode`.
class AniyomiSourceInfo {
  const AniyomiSourceInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
    required this.pkg,
    required this.nsfw,
    this.headers = const {},
    this.version = '',
    this.versionCode = 0,
  });

  /// Numeric source id matching `AnimeSource.id` on the native side.
  final int id;
  final String name;
  final String lang;

  /// The source's base URL; empty string for non-HTTP sources.
  final String baseUrl;

  /// Package name of the owning extension APK.
  final String pkg;

  /// Extension versionName from the APK manifest (e.g. "1.4.21"). Display only.
  final String version;

  /// Extension versionCode from the APK manifest. Update comparisons use this.
  final int versionCode;

  /// Whether the extension is flagged as not-safe-for-work.
  final bool nsfw;

  /// Default HTTP headers for this source (e.g. Referer, User-Agent).
  ///
  /// Required by some image hosts to serve thumbnails without 403 errors.
  /// Empty map for non-HTTP sources or sources that don't set custom headers.
  final Map<String, String> headers;

  /// Deserialises one element of the JSON array produced by the native bridge.
  factory AniyomiSourceInfo.fromJson(Map<String, dynamic> json) {
    return AniyomiSourceInfo(
      id: (json['id'] as num).toInt(),
      name: (json['name'] as String?) ?? '',
      lang: (json['lang'] as String?) ?? '',
      baseUrl: (json['baseUrl'] as String?) ?? '',
      pkg: (json['pkg'] as String?) ?? '',
      version: (json['version'] as String?) ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      // Native side serialises a Kotlin Boolean → JSON true/false.
      nsfw: (json['nsfw'] as bool?) ?? false,
      // Native side serialises source-level OkHttp headers as a JSON object.
      headers: (json['headers'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
    );
  }
}
