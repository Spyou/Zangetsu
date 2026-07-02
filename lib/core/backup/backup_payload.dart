enum BackupBundle { sources, library, settings }

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'BackupFormatException: $message';
}

const _kApp = 'zangetsu';
const _kVersion = 1;

Map<String, dynamic> wrapPayload(
  Map<BackupBundle, Map<String, dynamic>> bundles, {
  required String createdAtIso,
}) => {
      'app': _kApp,
      'version': _kVersion,
      'createdAt': createdAtIso,
      'bundles': {for (final e in bundles.entries) e.key.name: e.value},
    };

Map<BackupBundle, Map<String, dynamic>> unwrapPayload(Map<String, dynamic> raw) {
  if (raw['app'] != _kApp) {
    throw const BackupFormatException("This isn't a Zangetsu backup.");
  }
  if ((raw['version'] as num? ?? 0) > _kVersion) {
    throw const BackupFormatException('Made by a newer version of Zangetsu.');
  }
  final bundles = (raw['bundles'] as Map?) ?? const {};
  final out = <BackupBundle, Map<String, dynamic>>{};
  for (final b in BackupBundle.values) {
    final v = bundles[b.name];
    if (v is Map) out[b] = Map<String, dynamic>.from(v);
  }
  return out;
}
