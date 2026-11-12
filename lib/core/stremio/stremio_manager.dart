import 'dart:collection';
import 'dart:convert' show jsonEncode;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

import '../hive/safe_box.dart';
import 'stremio_link_session.dart';
import 'stremio_ref.dart';

/// Secret storage for configured addon base URLs.
///
/// URLs can carry debrid keys or account tokens, so they never go into Hive,
/// logs or exports.
abstract class StremioSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class StremioSecureStore implements StremioSecretStore {
  const StremioSecureStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class StremioInstallException implements Exception {
  const StremioInstallException(this.message);

  final String message;

  @override
  String toString() => 'Stremio: $message';
}

/// One installed addon. The configured URL lives in secure storage; this is
/// the public snapshot plus local state.
class StremioInstallation {
  const StremioInstallation({
    required this.id,
    required this.name,
    required this.version,
    required this.manifestId,
    required this.types,
    required this.idPrefixes,
    required this.resources,
    required this.catalogs,
    required this.enabled,
    required this.revision,
    required this.createdAt,
    required this.urlDigest,
    this.description,
    this.logo,
    this.position,
    this.hiddenCatalogs = const [],
    this.configurationUrl,
    this.configurable = false,
  });

  final String id;
  final String name;
  final String version;
  final String manifestId;
  final List<String> types;
  final List<String> idPrefixes;
  final List<StremioResourceDescriptor> resources;
  final List<StremioCatalog> catalogs;
  final bool enabled;
  final int revision;
  final int createdAt;
  final String urlDigest;
  final String? description;
  final String? logo;
  final int? position;
  final List<String> hiddenCatalogs;
  final String? configurationUrl;
  final bool configurable;

  StremioInstallation copyWith({
    bool? enabled,
    int? revision,
    int? position,
    List<String>? hiddenCatalogs,
  }) => StremioInstallation(
    id: id,
    name: name,
    version: version,
    manifestId: manifestId,
    types: types,
    idPrefixes: idPrefixes,
    resources: resources,
    catalogs: catalogs,
    enabled: enabled ?? this.enabled,
    revision: revision ?? this.revision,
    createdAt: createdAt,
    urlDigest: urlDigest,
    description: description,
    logo: logo,
    position: position ?? this.position,
    hiddenCatalogs: hiddenCatalogs ?? this.hiddenCatalogs,
    configurationUrl: configurationUrl,
    configurable: configurable,
  );

  bool isCatalogVisible(String type, String catalogId) =>
      !hiddenCatalogs.contains(jsonEncode([type, catalogId]));

  bool supports(String resource) => resources.any((r) => r.name == resource);

  StremioResourceDescriptor? resource(String name) {
    for (final r in resources) {
      if (r.name == name) return r;
    }
    return null;
  }

  bool accepts(String type, String itemId, {String resourceName = 'stream'}) {
    if (types.isNotEmpty && !types.contains(type)) return false;
    final specific = resource(resourceName);
    if (specific == null) return true;
    if (!specific.acceptsType(type)) return false;
    return specific.acceptsId(itemId) &&
        (idPrefixes.isEmpty || idPrefixes.any((p) => itemId.startsWith(p)));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'manifestId': manifestId,
    'types': types,
    'idPrefixes': idPrefixes,
    'resources': resources
        .map(
          (r) => {'name': r.name, 'types': r.types, 'idPrefixes': r.idPrefixes},
        )
        .toList(growable: false),
    'catalogs': catalogs
        .map(
          (c) => {
            'type': c.type,
            'id': c.id,
            'name': c.name,
            'extras': c.extras
                .map(
                  (e) => {
                    'name': e.name,
                    'isRequired': e.isRequired,
                    'options': e.options,
                  },
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false),
    'enabled': enabled,
    'revision': revision,
    'createdAt': createdAt,
    'urlDigest': urlDigest,
    'description': description,
    'logo': logo,
    'position': position,
    'hiddenCatalogs': hiddenCatalogs,
    'configurationUrl': configurationUrl,
    'configurable': configurable,
  };

  static StremioInstallation fromJson(Map<String, dynamic> json) {
    return StremioInstallation(
      id: json['id'] as String,
      name: json['name'] as String,
      version: json['version'] as String,
      manifestId: json['manifestId'] as String,
      types: (json['types'] as List?)?.cast<String>() ?? const [],
      idPrefixes: (json['idPrefixes'] as List?)?.cast<String>() ?? const [],
      resources: ((json['resources'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (r) => StremioResourceDescriptor(
              name: r['name'] as String,
              types: (r['types'] as List?)?.cast<String>() ?? const [],
              idPrefixes:
                  (r['idPrefixes'] as List?)?.cast<String>() ?? const [],
            ),
          )
          .toList(growable: false),
      catalogs: ((json['catalogs'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (c) => StremioCatalog(
              type: c['type'] as String,
              id: c['id'] as String,
              name: c['name'] as String,
              extras: ((c['extras'] as List?) ?? const [])
                  .whereType<Map>()
                  .map(
                    (e) => StremioExtra(
                      name: e['name'] as String,
                      isRequired: e['isRequired'] == true,
                      options:
                          (e['options'] as List?)?.cast<String>() ?? const [],
                    ),
                  )
                  .toList(growable: false),
            ),
          )
          .toList(growable: false),
      enabled: json['enabled'] != false,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      urlDigest: json['urlDigest'] as String? ?? '',
      description: json['description'] as String?,
      logo: json['logo'] as String?,
      position: (json['position'] as num?)?.toInt(),
      hiddenCatalogs:
          (json['hiddenCatalogs'] as List?)?.whereType<String>().toList() ??
          const [],
      configurationUrl: json['configurationUrl'] as String?,
      configurable: json['configurable'] == true,
    );
  }
}

class _Cached {
  _Cached(this.value, this.expires);

  final Object? value;
  final DateTime expires;
}

/// Owns installed Stremio addons, their secrets, bounded caches and request
/// coalescing. The protocol client stays HTTP-only.
class StremioManager extends ChangeNotifier {
  StremioManager({
    StremioClient? client,
    StremioSecretStore? secrets,
    DateTime Function()? clock,
    this.manifestTtl = const Duration(minutes: 15),
    this.metaTtl = const Duration(minutes: 5),
    this.streamsTtl = const Duration(seconds: 30),
    this.allowHttp = false,
    this.maxCacheEntries = 200,
  }) : _client = client ?? StremioClient(allowHttp: allowHttp),
       _secrets = secrets ?? const StremioSecureStore(),
       _clock = clock ?? DateTime.now;

  static const String boxName = 'stremio_installations';
  static const String _secretPrefix = 'stremio:base:';
  static const _defaultMetadataRemovedKey = '_default_metadata_removed';

  final StremioClient _client;
  final StremioSecretStore _secrets;
  final DateTime Function() _clock;
  final Duration manifestTtl;
  final Duration metaTtl;
  final Duration streamsTtl;
  final bool allowHttp;
  final int maxCacheEntries;

  final Map<String, StremioInstallation> _installations = {};
  final LinkedHashMap<String, _Cached> _cache = LinkedHashMap();
  final Map<String, Future<Object?>> _inflight = {};
  var _initialized = false;
  var _sequence = 0;
  var _revision = 0;

  bool get isInitialized => _initialized;

  /// Bumped on every successful install/configure/enable/remove, so source
  /// pickers and Home can refresh without polling the box.
  int get revision => _revision;

  List<StremioInstallation> get installations {
    final list = _installations.values.toList()
      ..sort((a, b) {
        final byCreated = (a.position ?? a.createdAt).compareTo(
          b.position ?? b.createdAt,
        );
        return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
      });
    return List.unmodifiable(list);
  }

  List<StremioInstallation> get enabled =>
      installations.where((i) => i.enabled).toList(growable: false);

  StremioInstallation? byId(String id) => _installations[id];

  bool canOpen(StremioRef ref, {int? revision}) {
    if (isVerifiedStremioId(ref.itemId)) return true;
    final origin = byId(ref.installationId);
    return origin != null &&
        origin.enabled &&
        (revision == null || origin.revision == revision);
  }

  Future<void> init() async {
    if (_initialized) return;
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box<Map>(boxName)
        : await openBoxSafely<Map>(boxName);
    _installations
      ..clear()
      ..addEntries(
        box.keys.where((key) => key != _defaultMetadataRemovedKey).map((key) {
          final raw = box.get(key);
          final installation = StremioInstallation.fromJson(
            Map<String, dynamic>.from(raw!),
          );
          return MapEntry(installation.id, installation);
        }),
      );
    _initialized = true;
  }

  static const defaultMetadataId = 'stremio_cinemeta';
  static const defaultMetadataUrl = 'https://v3-cinemeta.strem.io';

  /// Seed public metadata without holding startup on a network request.
  Future<void> ensureDefaultMetadata() async {
    await init();
    if ((await _box).get(_defaultMetadataRemovedKey)?['removed'] == true) {
      return;
    }
    final current = _installations[defaultMetadataId];
    if (_installations.values.any(
          (i) =>
              i.manifestId == 'com.linvo.cinemeta' && i.id != defaultMetadataId,
        ) ||
        (current != null && current.catalogs.length != 2)) {
      return;
    }
    const extras = [StremioExtra(name: 'search'), StremioExtra(name: 'skip')];
    final yearExtras = [
      StremioExtra(
        name: 'genre',
        isRequired: true,
        options: ['${_clock().year}'],
      ),
      const StremioExtra(name: 'skip'),
    ];
    final item =
        _fromManifest(
          id: defaultMetadataId,
          manifest: StremioManifest(
            id: 'com.linvo.cinemeta',
            name: 'Cinemeta',
            version: '3.0.0',
            description: 'Movie and series catalogues and metadata',
            types: ['movie', 'series'],
            idPrefixes: ['tt'],
            resources: [
              StremioResourceDescriptor(name: 'catalog'),
              StremioResourceDescriptor(name: 'meta'),
            ],
            catalogs: [
              for (final type in ['movie', 'series'])
                StremioCatalog(
                  type: type,
                  id: 'top',
                  name: 'Popular',
                  extras: extras,
                ),
              for (final type in ['movie', 'series'])
                StremioCatalog(
                  type: type,
                  id: 'year',
                  name: 'New',
                  extras: yearExtras,
                ),
              for (final type in ['movie', 'series'])
                StremioCatalog(
                  type: type,
                  id: 'imdbRating',
                  name: 'Featured',
                  extras: const [StremioExtra(name: 'skip')],
                ),
            ],
          ),
          digest: _digest(Uri.parse(defaultMetadataUrl)),
          createdAt: current?.createdAt ?? 0,
          revision: (current?.revision ?? -1) + 1,
          enabled: current?.enabled ?? true,
        ).copyWith(
          position: current?.position,
          hiddenCatalogs: current?.hiddenCatalogs,
        );
    await (await _box).put(item.id, item.toJson());
    _installations[item.id] = item;
    _revision++;
    notifyListeners();
  }

  Future<StremioInstallation> install(String rawUrl) async {
    await init();
    final base = _normalize(rawUrl);
    final digest = _digest(base);
    if (_installations.values.any((i) => i.urlDigest == digest)) {
      throw const StremioInstallException('addon is already installed');
    }
    final manifest = await _client.manifest(base);
    final id = 'stremio_${_clock().microsecondsSinceEpoch}_${_sequence++}';
    final installation = _fromManifest(
      id: id,
      manifest: manifest,
      digest: digest,
      createdAt: _clock().millisecondsSinceEpoch,
      revision: 0,
      enabled: true,
    );

    await _writeSecret(id, base);
    try {
      final box = await _box;
      await box.put(id, installation.toJson());
    } catch (_) {
      await _deleteSecret(id);
      rethrow;
    }
    _installations[id] = installation;
    _cache.clear();
    _store('m|$id|0', manifest, manifestTtl);
    _revision++;
    notifyListeners();
    return installation;
  }

  /// Replaces the configured URL of an existing installation while keeping its
  /// stable local id.
  Future<StremioInstallation> configure(String id, String rawUrl) async {
    await init();
    final current = _require(id);
    final base = _normalize(rawUrl);
    final digest = _digest(base);
    if (_installations.values.any((i) => i.id != id && i.urlDigest == digest)) {
      throw const StremioInstallException('addon is already installed');
    }
    final manifest = await _client.manifest(base);
    final oldSecret = await _readSecret(id);
    await _writeSecret(id, base);
    final updated = _fromManifest(
      id: id,
      manifest: manifest,
      digest: digest,
      createdAt: current.createdAt,
      revision: current.revision + 1,
      enabled: current.enabled,
    );
    try {
      final box = await _box;
      await box.put(
        id,
        updated
            .copyWith(
              position: current.position,
              hiddenCatalogs: current.hiddenCatalogs,
            )
            .toJson(),
      );
    } catch (_) {
      if (oldSecret != null) {
        await _writeSecretValue(id, oldSecret);
      } else {
        await _deleteSecret(id);
      }
      rethrow;
    }
    final orderedUpdate = updated.copyWith(
      position: current.position,
      hiddenCatalogs: current.hiddenCatalogs,
    );
    _installations[id] = orderedUpdate;
    _invalidate(id);
    _store('m|$id|${updated.revision}', manifest, manifestTtl);
    _revision++;
    notifyListeners();
    return orderedUpdate;
  }

  Future<void> move(String id, int direction) async {
    await init();
    final ordered = installations.toList();
    final index = ordered.indexWhere((item) => item.id == id);
    final target = index + direction;
    if (index < 0 || target < 0 || target >= ordered.length) return;
    final item = ordered.removeAt(index);
    ordered.insert(target, item);
    final updates = <String, Map<String, dynamic>>{};
    final changed = <StremioInstallation>[];
    for (var i = 0; i < ordered.length; i++) {
      final entry = ordered[i].copyWith(position: i);
      updates[entry.id] = entry.toJson();
      changed.add(entry);
    }
    await (await _box).putAll(updates);
    for (final entry in changed) {
      _installations[entry.id] = entry;
    }
    _revision++;
    notifyListeners();
  }

  Future<void> setCatalogVisible(
    String id,
    String type,
    String catalogId,
    bool visible,
  ) async {
    await init();
    final current = _require(id);
    if (!current.catalogs.any((c) => c.type == type && c.id == catalogId)) {
      throw const StremioInstallException('catalogue is unavailable');
    }
    if (current.isCatalogVisible(type, catalogId) == visible) return;
    final hidden = current.hiddenCatalogs.toSet();
    final key = jsonEncode([type, catalogId]);
    if (visible) {
      hidden.remove(key);
    } else {
      hidden.add(key);
    }
    final updated = current.copyWith(hiddenCatalogs: hidden.toList());
    await (await _box).put(id, updated.toJson());
    _installations[id] = updated;
    _revision++;
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await init();
    final current = _require(id);
    if (current.enabled == enabled) return;
    final updated = current.copyWith(
      enabled: enabled,
      revision: current.revision + 1,
    );
    final box = await _box;
    await box.put(
      id,
      updated
          .copyWith(
            position: current.position,
            hiddenCatalogs: current.hiddenCatalogs,
          )
          .toJson(),
    );
    _installations[id] = updated;
    _invalidate(id);
    _revision++;
    notifyListeners();
  }

  /// Starts a cancellable, ordered link collection for one Stremio episode.
  /// The sheet owns the session and disposes it when it closes.
  StremioLinkSession openLinks(
    StremioRef ref, {
    List<StremioStream> inlineStreams = const [],
    int activeLimit = 4,
  }) => StremioLinkSession.start(
    this,
    ref,
    inlineStreams: inlineStreams,
    activeLimit: activeLimit,
  );

  Future<void> remove(String id) async {
    await init();
    final installation = _require(id);
    final box = await _box;
    if (id == defaultMetadataId ||
        installation.manifestId == 'com.linvo.cinemeta') {
      await box.put(_defaultMetadataRemovedKey, {'removed': true});
    }
    await box.delete(id);
    await _deleteSecret(id);
    _installations.remove(id);
    _invalidate(id);
    _revision++;
    notifyListeners();
  }

  Future<Uri?> baseUri(String id) async {
    final secret = await _readSecret(id);
    if (secret == null && id == defaultMetadataId) {
      return Uri.parse(defaultMetadataUrl);
    }
    if (secret == null) return null;
    return Uri.tryParse(secret);
  }

  Future<StremioManifest> manifest(String id) async {
    final installation = await _installed(id);
    final key = 'm|$id|${installation.revision}';
    final cached = _cacheEntry(key);
    if (cached != null) return cached.value as StremioManifest;
    return _coalesce(key, () async {
      final manifest = await _client.manifest(await _base(id));
      _store(key, manifest, manifestTtl);
      return manifest;
    });
  }

  Future<StremioCatalogPage> catalog(
    String id, {
    required String type,
    required String catalogId,
    String? search,
    int? skip,
    String? genre,
  }) async {
    final installation = await _installed(id);
    final key =
        'c|$id|${installation.revision}|$type|$catalogId|'
        '${search ?? ''}|${skip ?? ''}|${genre ?? ''}';
    return _coalesce(key, () async {
      final page = await _client.catalog(
        await _base(id),
        type: type,
        catalogId: catalogId,
        search: search,
        skip: skip,
        genre: genre,
      );
      return page;
    });
  }

  Future<StremioMeta?> meta(
    String id, {
    required String type,
    required String itemId,
  }) async {
    final installation = await _installed(id);
    final key = 't|$id|${installation.revision}|$type|$itemId';
    final cached = _cacheEntry(key);
    if (cached != null) return cached.value as StremioMeta?;
    return _coalesce(key, () async {
      final meta = await _client.meta(await _base(id), type: type, id: itemId);
      _store(key, meta, metaTtl);
      return meta;
    });
  }

  Future<List<StremioStream>> streams(
    String id, {
    required String type,
    required String itemId,
  }) async {
    final installation = await _installed(id);
    final key = 's|$id|${installation.revision}|$type|$itemId';
    final cached = _cacheEntry(key);
    if (cached != null) return cached.value as List<StremioStream>;
    return _coalesce(key, () async {
      final streams = await _client.streams(
        await _base(id),
        type: type,
        id: itemId,
      );
      _store(key, streams, streamsTtl);
      return streams;
    });
  }

  void rememberSubtitleStream(
    StremioRef ref,
    String url,
    StremioStream stream,
  ) {
    final key = 'subtitle-stream|${ref.encode()}';
    final tracks = _cacheEntry(key)?.value as Map<String, StremioStream>? ?? {};
    tracks[url] = stream;
    _store(key, tracks, const Duration(hours: 2));
  }

  StremioStream subtitleStream(StremioRef ref, String url) {
    final tracks =
        _cacheEntry('subtitle-stream|${ref.encode()}')?.value
            as Map<String, StremioStream>?;
    return tracks?[url] ??
        StremioStream(kind: StremioStreamKind.direct, url: url);
  }

  Future<List<StremioSubtitle>> subtitles(
    String id, {
    required String type,
    required String itemId,
    String? filename,
    String? videoHash,
    int? videoSize,
  }) async {
    await _installed(id);
    final key =
        'u|$id|$type|$itemId|${filename ?? ''}|'
        '${videoHash ?? ''}|${videoSize ?? ''}';
    return _coalesce(
      key,
      () async => _client.subtitles(
        await _base(id),
        type: type,
        id: itemId,
        filename: filename,
        videoHash: videoHash,
        videoSize: videoSize,
      ),
    );
  }

  @visibleForTesting
  int get cacheSize => _cache.length;

  // ---------------------------------------------------------------------

  Future<Box<Map>> get _box async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
    return Hive.box<Map>(boxName);
  }

  StremioInstallation _require(String id) {
    final installation = _installations[id];
    if (installation == null) {
      throw const StremioInstallException('addon is not installed');
    }
    return installation;
  }

  Future<StremioInstallation> _installed(String id) async {
    await init();
    return _require(id);
  }

  Future<Uri> _base(String id) async {
    final uri = await baseUri(id);
    if (uri == null) {
      throw const StremioInstallException('addon URL is unavailable');
    }
    return uri;
  }

  StremioInstallation _fromManifest({
    required String id,
    required StremioManifest manifest,
    required String digest,
    required int createdAt,
    required int revision,
    required bool enabled,
  }) {
    return StremioInstallation(
      id: id,
      name: manifest.name,
      version: manifest.version,
      manifestId: manifest.id,
      types: manifest.types,
      idPrefixes: manifest.idPrefixes,
      resources: manifest.resources,
      catalogs: manifest.catalogs,
      enabled: enabled,
      revision: revision,
      createdAt: createdAt,
      urlDigest: digest,
      description: manifest.description,
      logo: manifest.logo,
      configurationUrl: manifest.configurationUrl?.toString(),
      configurable: manifest.configurable,
    );
  }

  Uri _normalize(String raw) {
    final text = raw.trim();
    final parsed = Uri.tryParse(
      text.startsWith('stremio://')
          ? 'https://${text.substring('stremio://'.length)}'
          : text,
    );
    if (parsed == null || !parsed.hasAuthority || parsed.host.isEmpty) {
      throw const StremioInstallException('invalid addon URL');
    }
    if (parsed.scheme != 'https' && !(allowHttp && parsed.scheme == 'http')) {
      throw const StremioInstallException('addon URL must use HTTPS');
    }
    final segments = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && segments.last == 'manifest.json') {
      segments.removeLast();
    }
    final clean = parsed.hasFragment
        ? Uri.parse(parsed.toString().split('#').first)
        : parsed;
    return clean.replace(pathSegments: segments);
  }

  String _digest(Uri uri) =>
      sha256.convert(uri.toString().codeUnits).toString();

  String _secretKey(String id) => '$_secretPrefix$id';

  Future<String?> _readSecret(String id) async {
    try {
      return await _secrets.read(_secretKey(id));
    } catch (_) {
      throw const StremioInstallException('secure storage is unavailable');
    }
  }

  Future<void> _writeSecret(String id, Uri uri) =>
      _writeSecretValue(id, uri.toString());

  Future<void> _writeSecretValue(String id, String value) async {
    try {
      await _secrets.write(_secretKey(id), value);
    } catch (_) {
      throw const StremioInstallException('secure storage is unavailable');
    }
  }

  Future<void> _deleteSecret(String id) async {
    try {
      await _secrets.delete(_secretKey(id));
    } catch (_) {
      // A stale secret for a removed local id is inert.
    }
  }

  _Cached? _cacheEntry(String key) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    if (!entry.expires.isAfter(_clock())) return null;
    _cache[key] = entry;
    return entry;
  }

  void _store(String key, Object? value, Duration ttl) {
    _cache.remove(key);
    _cache[key] = _Cached(value, _clock().add(ttl));
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<T> _coalesce<T>(String key, Future<T> Function() body) {
    final existing = _inflight[key];
    if (existing != null) return existing.then((value) => value as T);
    final future = body();
    _inflight[key] = future;
    return future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
  }

  void _invalidate(String id) {
    _cache.removeWhere((key, _) {
      final parts = key.split('|');
      return parts.length > 1 && parts[1] == id;
    });
  }
}
