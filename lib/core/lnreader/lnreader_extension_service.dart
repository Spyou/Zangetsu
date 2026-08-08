import 'dart:convert';

import 'package:hive/hive.dart';

/// One entry from the LNReader plugin index (`plugins.min.json`) — a novel
/// source plugin's install metadata. The novel-side twin of
/// `MihonSourceInfo` (`lib/core/mihon/mihon_source_info.dart`), but simpler:
/// Hive-serializable as a plain Map (see [toMap]/[fromMap]) rather than a
/// registered TypeAdapter, same choice `ProviderRegistryEntry`
/// (`lib/core/provider/provider_registry.dart`) makes for its box.
class LnReaderPluginMeta {
  const LnReaderPluginMeta({
    required this.id,
    required this.name,
    required this.site,
    required this.lang,
    required this.version,
    required this.url,
    required this.iconUrl,
  });

  final String id;
  final String name;
  final String site;
  final String lang;
  final String version;

  /// The plugin's JS source file — what [LnReaderExtensionService.install]
  /// downloads.
  final String url;
  final String iconUrl;

  factory LnReaderPluginMeta.fromMap(Map<dynamic, dynamic> j) =>
      LnReaderPluginMeta(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        site: (j['site'] as String?) ?? '',
        lang: (j['lang'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        iconUrl: (j['iconUrl'] as String?) ?? '',
      );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'site': site,
    'lang': lang,
    'version': version,
    'url': url,
    'iconUrl': iconUrl,
  };
}

/// Fetches the LNReader plugin index and installs/stores novel-source
/// plugins in the `lnreader_plugins` Hive box — the novel twin of
/// `MihonExtensionService`'s repo-index + install tracking. Deliberately
/// duplicated rather than shared, same rationale as every other *Reader/
/// *Mihon twin in this codebase (see `mihon_extension_service.dart`).
///
/// Unlike Mihon (native APKs, installed through a MethodChannel), an
/// LNReader plugin is just a JS source file: [install] downloads it via
/// [httpGet] and stores the source itself (not just a path) in the box,
/// keyed by plugin id, so `LnReaderManager` can load it into the QuickJS
/// runtime without a second network round trip.
///
/// [httpGet] is injected — rather than reaching for a shared Dio/http client
/// directly — so this class and its tests stay decoupled from the app's HTTP
/// stack. Task 6 wires the real implementation.
///
/// Assumes the [boxName] box is already open (opened by
/// `LnReaderManager.init()`); this class never opens or closes it itself.
class LnReaderExtensionService {
  LnReaderExtensionService({required this.httpGet});

  final Future<String> Function(String url) httpGet;

  /// Hive box name for installed plugins. Each entry is a Map:
  /// `{id, name, site, lang, version, url, iconUrl, js}`, keyed by
  /// [LnReaderPluginMeta.id].
  static const String boxName = 'lnreader_plugins';

  /// Pinned LNReader plugin index — a JSON array of
  /// `{id, name, site, lang, version, url, iconUrl}`.
  static const String indexUrl =
      'https://raw.githubusercontent.com/LNReader/lnreader-plugins/plugins/v3.0.0/.dist/plugins.min.json';

  Box<Map> get _box => Hive.box<Map>(boxName);

  /// Fetches and parses the plugin index.
  Future<List<LnReaderPluginMeta>> fetchIndex() async {
    final body = await httpGet(indexUrl);
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded.whereType<Map>().map(LnReaderPluginMeta.fromMap).toList();
  }

  /// Downloads [meta.url]'s JS source and stores it alongside [meta] in the
  /// box, keyed by [meta.id]. Overwrites any existing install of the same id.
  Future<void> install(LnReaderPluginMeta meta) async {
    final js = await httpGet(meta.url);
    await _box.put(meta.id, {...meta.toMap(), 'js': js});
  }

  /// All installed plugins' metadata (without their JS source).
  List<LnReaderPluginMeta> installed() =>
      _box.values.map(LnReaderPluginMeta.fromMap).toList();

  /// Removes the installed plugin with [id], if any.
  Future<void> uninstall(String id) => _box.delete(id);

  /// The stored JS source for the installed plugin [id], or null when not
  /// installed.
  String? jsFor(String id) => _box.get(id)?['js'] as String?;
}
