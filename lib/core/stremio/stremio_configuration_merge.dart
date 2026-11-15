import 'dart:convert';

bool stremioConfigurationsEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (key) =>
              b.containsKey(key) && stremioConfigurationsEqual(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => stremioConfigurationsEqual(a[i], b[i]),
        ).every((same) => same);
  }
  return a == b;
}

Map<String, dynamic> emptyStremioConfiguration() => {
  'version': 1,
  'installations': <Map<String, dynamic>>[],
  'aliases': <String, String>{},
  'defaultMetadataRemoved': false,
};

Map<String, Map<String, dynamic>> _entries(Map<String, dynamic>? state) => {
  for (final raw in state?['installations'] as List? ?? const [])
    (raw['metadata']['urlDigest'] as String): Map<String, dynamic>.from(
      raw as Map,
    ),
};

/// Three-way merge: independent edits combine; removals and saved remote fields win conflicts.
Map<String, dynamic> mergeStremioConfiguration(
  Map<String, dynamic>? base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote,
) {
  final before = _entries(base);
  final here = _entries(local);
  final there = _entries(remote);
  final deleted = <String>{
    ...List<String>.from(remote['deleted'] as List? ?? const []),
    ...before.keys.where((key) => !here.containsKey(key)),
  };
  final observedDeletions = (base?['deleted'] as List? ?? const []).toSet();
  deleted.removeWhere(
    (key) =>
        observedDeletions.contains(key) &&
        here.containsKey(key) &&
        !before.containsKey(key),
  );
  for (final entry in here.entries) {
    final key = entry.key;
    if (deleted.contains(key)) continue;
    final old = before[key];
    final saved = there[key];
    if (saved == null) {
      final id = entry.value['metadata']['id'];
      final idAlreadyUsed = there.values.any(
        (saved) => saved['metadata']['id'] == id,
      );
      if (old == null && !idAlreadyUsed) there[key] = entry.value;
      continue;
    }
    if (old == null || stremioConfigurationsEqual(entry.value, old)) continue;
    final metadata = Map<String, dynamic>.from(saved['metadata'] as Map);
    final oldMetadata = old['metadata'] as Map;
    final localMetadata = entry.value['metadata'] as Map;
    for (final field in localMetadata.keys) {
      if (const {'id', 'urlDigest', 'createdAt', 'revision'}.contains(field)) {
        continue;
      }
      if (field == 'hiddenCatalogs') {
        final previous = (oldMetadata[field] as List? ?? const []).toSet();
        final localHidden = (localMetadata[field] as List? ?? const []).toSet();
        final combined = (metadata[field] as List? ?? const []).toSet()
          ..removeAll(previous.difference(localHidden))
          ..addAll(localHidden.difference(previous));
        metadata[field] = combined.toList()
          ..sort((a, b) => '$a'.compareTo('$b'));
        continue;
      }
      if (!stremioConfigurationsEqual(
            oldMetadata[field],
            localMetadata[field],
          ) &&
          stremioConfigurationsEqual(oldMetadata[field], metadata[field])) {
        metadata[field] = localMetadata[field];
      }
    }
    there[key] = {...saved, 'metadata': metadata};
  }
  there.removeWhere((key, _) => deleted.contains(key));
  final ids = <String, String>{
    for (final entry in here.entries)
      if (there.containsKey(entry.key))
        entry.value['metadata']['id'] as String:
            there[entry.key]!['metadata']['id'] as String,
  };
  final aliases = <String, String>{
    ...Map<String, String>.from(remote['aliases'] as Map? ?? const {}),
    for (final entry in (local['aliases'] as Map? ?? const {}).entries)
      entry.key as String: ids[entry.value] ?? entry.value as String,
    for (final entry in ids.entries)
      if (entry.key != entry.value) entry.key: entry.value,
  };
  final validIds = there.values.map((entry) => entry['metadata']['id']).toSet();
  aliases.removeWhere(
    (key, target) => validIds.contains(key) || !validIds.contains(target),
  );
  final removedDefault =
      remote['defaultMetadataRemoved'] == true ||
      local['defaultMetadataRemoved'] == true;
  final result = {
    'version': 1,
    'installations': there.values.toList(),
    'aliases': aliases,
    'defaultMetadataRemoved': removedDefault,
    'deleted': deleted.toList()..sort(),
  };
  if (there.length > 200 ||
      utf8.encode(jsonEncode(result)).length > 1024 * 1024) {
    throw const FormatException('Addon configuration is too large');
  }
  return result;
}
