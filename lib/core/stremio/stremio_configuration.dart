part of 'stremio_manager.dart';

/// Configuration URLs are sensitive; callers must encrypt this before export.
extension StremioConfiguration on StremioManager {
  Future<Map<String, dynamic>> exportConfiguration() =>
      _write(_exportConfiguration);

  Future<Map<String, dynamic>> _exportConfiguration() async {
    await init();
    return {
      'version': 1,
      'defaultMetadataRemoved':
          (await _box).get(
            StremioManager._defaultMetadataRemovedKey,
          )?['removed'] ==
          true,
      'aliases': Map<String, String>.from(_aliases),
      'installations': [
        for (final item in installations)
          {
            'metadata': item.toJson()..['revision'] = 0,
            'url': (await _base(item.id)).toString(),
          },
      ],
    };
  }

  Future<void> transitionConfiguration({
    required Future<Map<String, dynamic>> Function(Map<String, dynamic>)
    prepare,
    required Future<void> Function() commit,
    required Future<void> Function() rollback,
  }) => _write(() async {
    final previous = await _exportConfiguration();
    var applied = false;
    try {
      final incoming = await prepare(previous);
      await _restoreConfiguration(incoming, merge: false);
      applied = true;
      if (incoming['seedDefault'] == true) await _ensureDefaultMetadata();
      await commit();
    } catch (_) {
      if (applied) await _restoreConfiguration(previous, merge: false);
      await rollback();
      throw const StremioInstallException(
        'could not switch addon configuration',
      );
    }
  });

  Future<void> restoreConfiguration(
    Map<String, dynamic> configuration, {
    bool merge = true,
    int? expectedRevision,
    bool validateOnly = false,
  }) => _write(
    () => _restoreConfiguration(
      configuration,
      merge: merge,
      expectedRevision: expectedRevision,
      validateOnly: validateOnly,
    ),
  );

  Future<void> _restoreConfiguration(
    Map<String, dynamic> configuration, {
    bool merge = true,
    int? expectedRevision,
    bool validateOnly = false,
  }) async {
    await init();
    if (expectedRevision != null && expectedRevision != revision) {
      throw const StremioInstallException('addon configuration changed; retry');
    }
    final entries = configuration['installations'];
    if (configuration['version'] != 1 ||
        entries is! List ||
        entries.length > 200 ||
        utf8.encode(jsonEncode(configuration)).length > 1024 * 1024) {
      throw const StremioInstallException('invalid addon configuration');
    }
    final box = await _box;
    final previous = Map<dynamic, Map>.from(box.toMap());
    final next = merge
        ? Map<String, StremioInstallation>.from(_installations)
        : <String, StremioInstallation>{};
    final aliases = merge
        ? Map<String, String>.from(_aliases)
        : <String, String>{};
    final urls = <String, Uri>{};
    final mappedIds = <String, String>{};
    try {
      for (final raw in entries) {
        if (raw is! Map || raw['metadata'] is! Map || raw['url'] is! String) {
          throw const FormatException();
        }
        final metadata = Map<String, dynamic>.from(raw['metadata'] as Map);
        final id = metadata['id'];
        if (id is! String ||
            !RegExp(r'^stremio_[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
            mappedIds.containsKey(id)) {
          throw const FormatException();
        }
        final url = _normalize(raw['url'] as String);
        final digest = _digest(url);
        if (metadata['urlDigest'] != digest) throw const FormatException();
        final duplicate = next.values
            .where((item) => item.urlDigest == digest)
            .firstOrNull;
        final target = duplicate?.id ?? id;
        mappedIds[id] = target;
        if (target != id) aliases[id] = target;
        if (next.containsKey(id) && next[id]!.urlDigest != digest) {
          throw const FormatException();
        }
        metadata['id'] = target;
        metadata['revision'] = (_installations[target]?.revision ?? -1) + 1;
        final item = StremioInstallation.fromJson(metadata);
        next[target] = item;
        urls[target] = url;
      }
      final importedAliases = configuration['aliases'];
      if (importedAliases != null) {
        if (importedAliases is! Map || importedAliases.length > 1000) {
          throw const FormatException();
        }
        for (final entry in importedAliases.entries) {
          final target = mappedIds[entry.value] ?? entry.value;
          if (entry.key is! String ||
              target is! String ||
              !next.containsKey(target) ||
              !RegExp(
                r'^stremio_[A-Za-z0-9_-]{1,128}$',
              ).hasMatch(entry.key as String)) {
            throw const FormatException();
          }
          if (entry.key != target) aliases[entry.key as String] = target;
        }
      }
    } catch (_) {
      throw const StremioInstallException('invalid addon configuration');
    }
    final removed =
        configuration['defaultMetadataRemoved'] == true ||
        (merge &&
            previous[StremioManager._defaultMetadataRemovedKey]?['removed'] ==
                true);
    if (removed && !mappedIds.containsKey(StremioManager.defaultMetadataId)) {
      next.remove(StremioManager.defaultMetadataId);
      urls.remove(StremioManager.defaultMetadataId);
    }
    aliases.removeWhere(
      (key, value) => next.containsKey(key) || !next.containsKey(value),
    );
    if (validateOnly) return;
    final oldSecrets = <String, String?>{};
    try {
      for (final entry in urls.entries) {
        oldSecrets[entry.key] = await _readSecret(entry.key);
        await _writeSecret(entry.key, entry.value);
      }
      await box.putAll({
        for (final item in next.values) item.id: item.toJson(),
        StremioManager._aliasesKey: aliases,
        StremioManager._defaultMetadataRemovedKey: {'removed': removed},
      });
      await box.deleteAll(
        _installations.keys.where((id) => !next.containsKey(id)),
      );
    } catch (_) {
      for (final entry in oldSecrets.entries) {
        try {
          if (entry.value == null) {
            await _deleteSecret(entry.key);
          } else {
            await _writeSecretValue(entry.key, entry.value!);
          }
        } catch (_) {
          /* Keep the original failure. */
        }
      }
      try {
        await box.deleteAll(
          next.keys.where((id) => !_installations.containsKey(id)),
        );
        await box.putAll(previous);
      } catch (_) {
        /* A storage failure must not publish a partial in-memory state. */
      }
      throw const StremioInstallException('could not save addon configuration');
    }
    final obsolete = _installations.keys
        .where((id) => !next.containsKey(id))
        .toList();
    _installations
      ..clear()
      ..addAll(next);
    _aliases
      ..clear()
      ..addAll(aliases);
    _configurationChanged();
    for (final id in obsolete) {
      try {
        await _deleteSecret(id);
      } catch (_) {
        /* Retry when this account is restored. */
      }
    }
  }
}
